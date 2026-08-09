#!/usr/bin/env bash
# DCRE version 1 direct cutover: drop every DCRE database and let each service's
# Liquibase build v1 from scratch.
#
# Owner directive, 2026-08-08:
#   "Drop all the DBs & perform a direct cut-over. Fix the Liquibase scripts.
#    Previously it was execution on the wrong designs, now that is executing on
#    the correct design. From now onwards it's version 1. Apply necessary changes
#    without hacking around the liquibase scripts."
#
# So this script does NOT pre-create history tables, does NOT pre-apply DDL and
# does NOT seed a changelog. It drops, it recreates six empty databases, and
# every table after that is minted by a changeset that actually ran. That is the
# whole point: a v1 schema nobody can prove came from the changelogs is not a v1
# schema, it is a coincidence.
#
# BASH, NOT ZSH, DELIBERATELY. Under zsh `for db in $LIST` does not word-split,
# so a roster becomes one long string and the loop runs once against nothing;
# and `PIPESTATUS` expands to the EMPTY STRING rather than erroring, which reads
# as success. Both have bitten this project.
#
# EXIT CODES. The three failure modes are never conflated:
#   0  cutover done, and every context database holds its own objects and no
#      other context's, in BOTH universes: service prefixes and exact relation
#      placement
#   1  a real violation: a database is absent, a context database holds another
#      context's objects, or a moved relation (public_holiday, account,
#      account_type) is in the wrong database
#   2  something could not be read or a step failed. NOTHING was learned; do not
#      read this as a clean result
#   3  PENDING: the databases are correct and empty, but no service Liquibase has
#      run yet, so the isolation audit has nothing to judge. Drive a warm-up
#      round, then re-run with --audit-only
set -u

# ---------------------------------------------------------------------------
# Config (12-factor: committed defaults target the local kind dev cluster)
# ---------------------------------------------------------------------------
NS="${DCRE_NS:-dcre}"
POD="${DCRE_CRDB_POD:-crdb-0}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The dev cluster, and nothing else. These are NOT overridable by environment on
# purpose: an override is exactly what a wrong-context run would set.
EXPECTED_CONTEXT="kind-dcre-dev"
EXPECTED_CLUSTER="kind-dcre-dev"
EXPECTED_NODE="dcre-dev-control-plane"

# One database per OWNING CONTEXT, never shared. agt_ops is orchestrator state.
#
# SCRUM-107 shared reference context. A database is named for the context that
# owns it: the three family databases keep family names because nine or ten
# services share each, and a single-service context takes the SERVICE's name.
# Hence dcre_hcs (holidays, owner hcs), not a topic name that would leave the
# owner unstated.
#
# FIVE, and dcre_acs is deliberately not the sixth. It existed for one day. The
# account registry that owned it had no authoritative source, no accountable
# owner, no ingestion of its own and no freshness contract, so it was a shared
# integration database wearing the costume of a bounded context. Account rows
# now live in each context's OWN database, materialised there by that context's
# own loader from ONE immutable versioned artifact.
DATABASES="agt_ops dcre_col dcre_man dcre_pay dcre_hcs"

# The service roster IS the diagrams (design-register R-49; scripts/verify-topology.sh).
# PRG IS THE PAYMENTS REPORT GENERATOR; the collections one is CRG. Read every
# occurrence in context: a find-and-replace on this token yields a file that
# parses and is semantically inverted.
SVC_COLLECTIONS="crr ctv cde crw cir cix csx cpx crg"
SVC_PAYMENTS="prr ptv pai prw pir pix psx ppx prg"
SVC_MANDATES="mrr mrv mas mit mir mrw mix msx mpx mrg"

# Single-service shared-reference contexts, each with its OWN database. They
# were cross-family before SCRUM-107 and hcs is no longer in any family's own
# roster: leaving it there would let an hcs history table in dcre_col count as
# one of dcre_col's OWN objects, which is precisely the state the split exists
# to end. They are foreign to every family database instead.
SVC_HOLIDAYS="hcs"      # owns dcre_hcs, holds public_holiday
# There is no SVC_ACCOUNTS. `acs` is retired and its repository is archived, so
# every list below that used to carry it is one name shorter. `account` is not a
# service's relation any more: it is a PROJECTION that three different contexts
# each hold a copy of, in their own databases, under their own constraints.

# Genuinely cross-family: rpt reads everywhere and owns no database of its own,
# so it is never counted as another context's object. Its objects live in the
# `rpt` SCHEMA, which this audit's public-schema universe does not cover at all.
SVC_SHARED="rpt"

FLOW_NAMESPACES="dcre-col dcre-pay dcre-man"

CONFIRM_FLAG="--yes-drop-everything"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
confirmed=0
audit_only=0
for arg in "$@"; do
  case "$arg" in
    "$CONFIRM_FLAG") confirmed=1 ;;
    --audit-only)    audit_only=1 ;;
    -h|--help)
      echo "usage: $0 [$CONFIRM_FLAG] [--audit-only]"
      echo "  $CONFIRM_FLAG  perform the drop. Without it this script refuses."
      echo "  --audit-only          skip the drop entirely; only run the"
      echo "                        per-context isolation audit and report."
      exit 0 ;;
    *)
      echo "REFUSED: unrecognised argument '$arg'."
      echo "         An argument this script does not understand is not ignored:"
      echo "         it is the shape a mistyped confirmation flag has."
      exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# The plan, printed FIRST and unconditionally, before any guard can exit
# ---------------------------------------------------------------------------
echo "=========================================================================="
echo "DCRE VERSION 1 DIRECT CUTOVER"
echo "=========================================================================="
if [ "$audit_only" -eq 1 ]; then
  echo "MODE: --audit-only. NOTHING will be dropped. Reporting only."
else
  echo "This will DROP the following databases IN FULL, with CASCADE, and"
  echo "recreate them EMPTY. Every row in them is destroyed and there is no"
  echo "backup step here and no undo:"
  for db in $DATABASES; do
    echo "    DROP DATABASE $db CASCADE;"
  done
  echo "Target: kube context '$EXPECTED_CONTEXT', namespace '$NS', pod '$POD'."
fi
echo "--------------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# Guard 1: the confirmation argument
# ---------------------------------------------------------------------------
if [ "$audit_only" -eq 0 ] && [ "$confirmed" -eq 0 ]; then
  echo "REFUSED: no confirmation argument."
  echo "         Re-run with $CONFIRM_FLAG once you have read the list above."
  echo "         Nothing has been touched."
  exit 2
fi

# ---------------------------------------------------------------------------
# Guard 2: the dev cluster, three independent checks, all fail closed
#
# A wrong-context run of this script is unrecoverable, so it is not enough for
# ONE thing to look right. The context NAME can be renamed by hand; the cluster
# entry and the control-plane node cannot be, without also being that cluster.
# ---------------------------------------------------------------------------
guard_cluster() {
  local rc ctx cluster nodes

  rc=0; ctx=$(kubectl config current-context 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$ctx" ]; then
    echo "REFUSED: could not read the current kube context (kubectl config"
    echo "         current-context exited $rc). Nothing was learned about which"
    echo "         cluster this would hit, which is itself a reason to stop."
    return 2
  fi
  if [ "$ctx" != "$EXPECTED_CONTEXT" ]; then
    echo "REFUSED: kube context is '$ctx', expected '$EXPECTED_CONTEXT'."
    echo "         This script destroys data. It runs against the dev cluster or"
    echo "         it does not run."
    return 2
  fi

  rc=0; cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$cluster" ]; then
    echo "REFUSED: could not read the cluster entry for context '$ctx'"
    echo "         (kubectl config view exited $rc)."
    return 2
  fi
  if [ "$cluster" != "$EXPECTED_CLUSTER" ]; then
    echo "REFUSED: context '$ctx' points at cluster '$cluster', expected"
    echo "         '$EXPECTED_CLUSTER'. A context can be renamed; the cluster it"
    echo "         points at is the thing that gets dropped."
    return 2
  fi

  rc=0; nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$nodes" ]; then
    echo "REFUSED: could not list nodes (kubectl get nodes exited $rc)."
    echo "         An unreachable cluster is not a safe cluster to drop."
    return 2
  fi
  case " $nodes " in
    *" $EXPECTED_NODE "*) ;;
    *) echo "REFUSED: no node named '$EXPECTED_NODE' in this cluster."
       echo "         got: $nodes"
       echo "         The kind dev cluster always has it. This is not that cluster."
       return 2 ;;
  esac

  echo "cluster guard PASS: context=$ctx cluster=$cluster node=$EXPECTED_NODE"
  return 0
}

guard_cluster || exit $?

# ---------------------------------------------------------------------------
# SQL helper. The database is a MANDATORY, EXPLICIT argument on every call.
#
# An earlier env-reset defaulted the connection database and seeded all 22
# Liquibase history tables into defaultdb while the verify step correctly found
# zero; a second bug hid it for a while. Defaults silently swallow DDL, so there
# is no default here and a caller that forgets is a hard error, not a guess.
#
# Deliberately NOT a pipeline: `x=$(cmd | tail); rc=$?` captures tail's status,
# and tail succeeds on anything, so a failed query reads as a successful empty
# one. Headers are stripped in-process by the callers instead.
# ---------------------------------------------------------------------------
CRDB_RC=0
REPLY_CSV=""
crdb() {
  local db="${1:-}" sql="${2:-}"
  REPLY_CSV=""
  if [ -z "$db" ]; then
    echo "BUG: crdb() called without an explicit database." >&2
    exit 2
  fi
  CRDB_RC=0
  REPLY_CSV=$(kubectl exec -n "$NS" "$POD" -- ./cockroach sql --insecure \
    --database="$db" --format=csv -e "$sql" 2>/dev/null) || CRDB_RC=$?
}

# CSV body without the header row, stripped in-process. `| tail -n +2` would put
# tail's status where the query's belongs, and tail succeeds on anything.
#
# THE CASE MATTERS, and a bare `${csv#*$'\n'}` gets it wrong. On a ZERO-ROW
# result cockroach emits the header and nothing else, command substitution eats
# the trailing newline, and the expansion then has no newline to match. A `#`
# pattern that does not match returns the string UNCHANGED, so the header comes
# back as if it were data: a listing query answers "one relation, named
# table_name" for an empty database, and a count query answers "count".
#
# That is not cosmetic. It makes every "is this database empty" branch
# unreachable, and it turns the information_schema control into a false PASS,
# because "count" is neither empty nor "0". Found by executing the empty-database
# case rather than reasoning about it; the stub reproduces cockroach exactly.
csv_rows() {
  case "$1" in
    *$'\n'*) printf '%s' "${1#*$'\n'}" ;;
    *)       printf '' ;;
  esac
}
csv_body() { csv_rows "$1"; }

# ---------------------------------------------------------------------------
# Phase 0: materialise the account reference artifact.
#
# WHAT THIS STAGES, AND WHAT IT DOES NOT RUN. This copies the versioned artifact
# into the exchange root, which is the DATA the three per-context loader jobs
# (CTV's accountReferenceLoadJob, PTV's ptvAccountReferenceLoadJob, MRV's
# mrvAccountReferenceLoadJob) read from the dcre-exchange PVC. RUNNING those
# loader jobs is a SEPARATE CONCERN and is deliberately not done here:
# --run-loaders is NOT passed, because that path has never been executed against
# a cluster and an unverified cluster call must not reach a cutover's default
# path. Staging without loading leaves the account tables empty; loading without
# staging is impossible. This step is the half that can be proven.
#
# FIRST, BEFORE THE DROP, and deliberately so. The step touches the local
# filesystem only and costs about a second. The alternative ordering destroys
# five databases and only then discovers there is no reference data to load into
# them, which leaves the environment strictly worse than it found it and forces a
# second full run. "Before the audit" is satisfied from any position in this
# script; "before anything irreversible" is satisfied only from here.
#
# IT HALTS THE CUTOVER. A cutover that proceeds without reference data produces
# exactly the misleading failure this change exists to remove: every verdict
# chain answers FAIL_ACCOUNT_NOT_FOUND, and a deployment step that never happened
# is then read for weeks as a data-quality problem. The exit codes line up
# already, so they are passed straight through: 1 is a real finding about the
# artifact, 2 is "nothing was learned".
# ---------------------------------------------------------------------------
materialise_reference() {
  local rc=0

  echo "[1/7] materialising the account reference artifact into the exchange root"
  echo "      (fixtures/reference/account -> exchange/reference/account, which a"
  echo "      stage pod reads as /exchange/reference/account/<version> through the"
  echo "      dcre-exchange PVC, the only volume a stage pod has)"
  bash "$HERE/materialise-account-reference.sh" || rc=$?
  echo "      materialise-account-reference.sh exited $rc (that status belongs to"
  echo "      that script; no pipeline is involved)"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Phase 1: quiesce. AGT must be down and stage Jobs gone before the drop, or a
# watcher/clock writes into a database that is being dropped and the drop's own
# schema-change jobs collide with a half-created table.
# ---------------------------------------------------------------------------
quiesce() {
  local rc

  echo "[2/7] scaling AGT to 0 (watcher, reconciler and clocks must not write"
  echo "      into a database that is being dropped)"
  rc=0; kubectl scale deploy dcre-agt -n "$NS" --replicas=0 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "      NOTE: kubectl scale exited $rc (deployment absent?). Continuing:"
    echo "      an absent AGT is already quiesced. This status belongs to the"
    echo "      scale command, not to anything below it."
  fi
  rc=0; kubectl wait --for=delete pod -l app=dcre-agt -n "$NS" --timeout=90s >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && echo "      NOTE: kubectl wait exited $rc; proceeding."

  echo "[3/7] deleting stage Jobs and pods in the flow namespaces"
  echo "      ($FLOW_NAMESPACES). crdb-0 lives in '$NS' and is NEVER touched,"
  echo "      nor is its PVC: this script drops DATABASES, not storage."
  for ns in $FLOW_NAMESPACES; do
    rc=0; kubectl delete jobs -n "$ns" --all --wait=false >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && echo "      NOTE: delete jobs in $ns exited $rc (namespace absent?)."
    rc=0; kubectl delete pods -n "$ns" --all --wait=false --grace-period=0 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && echo "      NOTE: delete pods in $ns exited $rc (namespace absent?)."
  done
  rc=0; kubectl delete jobs -n "$NS" --all --wait=false >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && echo "      NOTE: delete jobs in $NS exited $rc."
  return 0
}

# ---------------------------------------------------------------------------
# Phase 2: the drop, then the recreate.
#
# Connected to defaultdb EXPLICITLY. It is the one database that is not being
# dropped, and naming it is the point: the incident this guards against is a
# script that let the connection database default and wrote DDL somewhere nobody
# was looking.
# ---------------------------------------------------------------------------
drop_and_recreate() {
  local sql="" db

  echo "[4/7] dropping and recreating: $DATABASES"
  for db in $DATABASES; do
    sql="$sql DROP DATABASE IF EXISTS $db CASCADE;"
  done
  for db in $DATABASES; do
    sql="$sql CREATE DATABASE $db;"
  done

  crdb defaultdb "$sql"
  if [ "$CRDB_RC" -ne 0 ]; then
    echo "FAIL: the DROP/CREATE statement exited $CRDB_RC."
    echo "      That status belongs to the cockroach sql invocation itself, not"
    echo "      to any later step. The cluster may now be half-dropped: inspect"
    echo "      it before re-running."
    return 2
  fi
  echo "      DROP/CREATE exited 0 (status of the cockroach sql command)"

  echo "[5/7] draining CockroachDB schema-change jobs (DROP ... CASCADE returns"
  echo "      while its jobs still run; recreating into that window collides"
  echo "      with half-materialised metadata)"
  local waited=0 pending body
  while [ "$waited" -lt 120 ]; do
    crdb defaultdb "SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE','NEW SCHEMA CHANGE') AND status IN ('pending','running')"
    if [ "$CRDB_RC" -ne 0 ]; then
      echo "      NOTE: the job census exited $CRDB_RC; that is the census"
      echo "      command's status. Waiting the full budget instead of guessing."
      sleep 5; waited=$((waited + 5)); continue
    fi
    body="$(csv_body "$REPLY_CSV")"
    pending="$(printf '%s' "$body" | tr -d '\r\n ')"
    [ "$pending" = "0" ] && { echo "      schema-change jobs drained"; return 0; }
    sleep 5; waited=$((waited + 5))
  done
  echo "      WARN: schema-change jobs still pending after ${waited}s; continuing."
  return 0
}

# ---------------------------------------------------------------------------
# Phase 3: the per-context isolation audit. ONE step, two universes: service
# PREFIXES here, exact relation PLACEMENT in assert_relation_placement below.
# Both feed the same severity ranking and the same exit code.
#
# The whole point of the cutover is that payments objects stop landing in
# dcre_col. A cutover that "succeeds" while dcre_col still holds prw_* tables has
# failed, so the absence is asserted explicitly rather than assumed from the
# drop having exited 0.
#
# An absence found by searching proves nothing until a control proves the search
# can find. Two controls, both required before any absence is reported:
#   (a) information_schema in the connected database must be non-empty. If that
#       comes back empty the query mechanism is broken, whatever it exited.
#   (b) the database must hold at least one of its OWN service history tables.
#       Zero of its own means no changelog has run there yet, so "0 foreign
#       objects" is the trivially true statement about an empty database, not
#       evidence of isolation. That is reported PENDING, never PASS.
# ---------------------------------------------------------------------------
# Returns: 0 clean, 1 violation, 2 unreadable, 3 pending
audit_family_db() {
  local db="$1" own="$2" alien="$3" alien_label="$4"
  local body relations own_found own_missing alien_found svc control

  crdb "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema='information_schema'"
  if [ "$CRDB_RC" -ne 0 ]; then
    echo "  $db: FAIL(2) information_schema control query exited $CRDB_RC."
    echo "        That status is the cockroach sql command's. Nothing was learned"
    echo "        about what this database holds."
    return 2
  fi
  control="$(csv_rows "$REPLY_CSV" | tr -d '\r\n ')"
  if [ -z "$control" ] || [ "$control" = "0" ]; then
    echo "  $db: FAIL(2) the information_schema control returned '${control:-<empty>}'."
    echo "        Every database has an information_schema. This listing is not"
    echo "        trustworthy, so no absence may be read from it."
    return 2
  fi

  crdb "$db" "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
  if [ "$CRDB_RC" -ne 0 ]; then
    echo "  $db: FAIL(2) table listing exited $CRDB_RC (status of cockroach sql)."
    return 2
  fi
  body="$(csv_rows "$REPLY_CSV")"
  # Space-delimited with guaranteed leading and trailing separators, so every
  # entry is matchable, not just the first and last.
  local names=" $(printf '%s' "$body" | tr -d '\r' | tr '\n' ' ') "
  relations=$(printf '%s' "$names" | wc -w | tr -d ' ')

  own_found=""; own_missing=""
  for svc in $own; do
    case "$names" in
      *" ${svc}_databasechangelog "*) own_found="$own_found $svc" ;;
      *)                              own_missing="$own_missing $svc" ;;
    esac
  done

  alien_found=""
  for svc in $alien; do
    case "$names" in
      *" ${svc}_databasechangelog "*) alien_found="$alien_found ${svc}_databasechangelog" ;;
    esac
    # Not only the history table: any relation carrying a foreign service's
    # prefix is that service having written here.
    local t
    for t in $names; do
      case "$t" in
        "${svc}_"*)
          case " $alien_found " in
            *" $t "*) ;;
            *) alien_found="$alien_found $t" ;;
          esac ;;
      esac
    done
  done

  local n_own n_own_req n_alien
  n_own=$(printf '%s' "$own_found" | wc -w | tr -d ' ')
  n_own_req=$(printf '%s' "$own" | wc -w | tr -d ' ')
  n_alien=$(printf '%s' "$alien_found" | wc -w | tr -d ' ')

  # State the universe with the number, every time.
  printf "  %-9s %s relations in public, %s of %s own service histories present, %s %s-owned\n" \
    "$db:" "$relations" "$n_own" "$n_own_req" "$n_alien" "$alien_label"

  if [ "$n_alien" -gt 0 ]; then
    echo "        VIOLATION: $alien_label objects in $db:$alien_found"
    echo "        This is the exact defect the cutover exists to remove."
    if [ "$db" = "dcre_col" ]; then
      echo "        READ prg_* IN CONTEXT. On a PRE-cutover database these are the"
      echo "        LEGACY COLLECTIONS report generator's tables, which carried the"
      echo "        prg token before 2026-08-08 and are now called crg. On a POST-"
      echo "        cutover database the only thing that can create prg_* is the"
      echo "        PAYMENTS generator, and it has no business in dcre_col. Same"
      echo "        finding, two different causes, and only the drop separates them."
    fi
    return 1
  fi

  if [ "$n_own" -eq 0 ]; then
    echo "        PENDING: zero of its own service histories. No changelog has"
    echo "        run against $db yet, so '0 $alien_label-owned' is the trivially"
    echo "        true statement about an empty database and proves nothing."
    return 3
  fi

  [ -n "$own_missing" ] && echo "        not yet built:$own_missing"
  echo "        control: found its own histories ($own_found ), so the search"
  echo "        demonstrably works in this database and the absence above counts."
  return 0
}

# ---------------------------------------------------------------------------
# The same step, second half: relation PLACEMENT by exact name.
#
# audit_family_db above answers "did a foreign SERVICE write here", and it reads
# that off table-name PREFIXES. It is structurally blind to the SCRUM-107 move,
# because the relations that moved carry no service prefix at all: public_holiday
# and account are bare names, so a public_holiday sitting in dcre_col matches no
# service's prefix and the prefix audit reports the database clean. That is the
# fixture-monoculture shape of defect: the instrument cannot express the thing.
#
# So placement is asserted by exact relation name, in the SAME step, feeding the
# SAME severity ranking, and never as a parallel audit with its own exit path.
#
# Universe: every relation in the `public` schema, BASE TABLEs AND VIEWS. The
# table_type filter that audit_family_db uses is deliberately NOT applied here.
# "dcre_col contains zero relations named account" is false if a compatibility
# VIEW named account is left behind, and a view is the most likely way for one
# to survive a move.
#
# TWO CONTROLS, and they answer different questions:
#
#   (a) INSTRUMENT control, always required, checked FIRST. Searches
#       information_schema, through the same expression the payload uses, for
#       three relations every CockroachDB database has. If the search cannot
#       find those, it could not have found anything, so nothing is asserted and
#       the message says the INSTRUMENT failed. That wording is load-bearing: it
#       must never be confused with the assertion having failed, which is a
#       claim about the database rather than about the search.
#
#   (b) CONTENT control, required before any ABSENCE is reported clean. At least
#       one relation known to belong in this database must be found. Without it,
#       "zero relations named public_holiday" is the trivially true statement
#       about an empty database and is reported PENDING, never PASS.
#
# A relation found where it must NOT be needs no control at all: a positive find
# is self-evidencing. That case is therefore judged before either control gate.
#
# Returns: 0 clean, 1 assertion failed, 2 instrument failed, 3 pending
assert_relation_placement() {
  local db="$1" want_present="$2" want_absent="$3" content_control="$4"
  local rel ctl ctl_missing names n_public
  local found_control missing_present found_forbidden

  # ---- (a) instrument control ---------------------------------------------
  crdb "$db" "SELECT table_name FROM information_schema.tables WHERE table_schema='information_schema' AND table_name IN ('tables','columns','schemata') ORDER BY table_name"
  if [ "$CRDB_RC" -ne 0 ]; then
    echo "  $db: INSTRUMENT FAILED. The control query exited $CRDB_RC (that is the"
    echo "        cockroach sql command's own status). NO assertion was evaluated"
    echo "        against $db: this is not an assertion failure, it is the search"
    echo "        never having run."
    return 2
  fi
  ctl=" $(csv_rows "$REPLY_CSV" | tr -d '\r' | tr '\n' ' ') "
  ctl_missing=""
  for rel in tables columns schemata; do
    case "$ctl" in
      *" $rel "*) ;;
      *) ctl_missing="$ctl_missing $rel" ;;
    esac
  done
  if [ -n "$ctl_missing" ]; then
    echo "  $db: INSTRUMENT FAILED. The control searched information_schema for 3"
    echo "        relations that every CockroachDB database has and did not find:$ctl_missing"
    echo "        got:$ctl"
    echo "        A search that cannot find a relation which is certainly present"
    echo "        cannot establish that any other relation is absent. NO assertion"
    echo "        was evaluated against $db. This is NOT an assertion failure."
    return 2
  fi

  # ---- payload -------------------------------------------------------------
  crdb "$db" "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name"
  if [ "$CRDB_RC" -ne 0 ]; then
    echo "  $db: INSTRUMENT FAILED. The public-schema listing exited $CRDB_RC"
    echo "        (status of cockroach sql). Nothing was learned about placement."
    return 2
  fi
  names=" $(csv_rows "$REPLY_CSV" | tr -d '\r' | tr '\n' ' ') "
  n_public=$(printf '%s' "$names" | wc -w | tr -d ' ')

  found_forbidden=""
  for rel in $want_absent; do
    case "$names" in
      *" $rel "*) found_forbidden="$found_forbidden $rel" ;;
    esac
  done
  missing_present=""
  for rel in $want_present; do
    case "$names" in
      *" $rel "*) ;;
      *) missing_present="$missing_present $rel" ;;
    esac
  done
  found_control=""
  for rel in $content_control; do
    case "$names" in
      *" $rel "*) found_control="$found_control $rel" ;;
    esac
  done

  # State the universe with the number, every time.
  printf "  %-9s placement: %s relations in public (tables+views); want present [%s], want absent [%s]\n" \
    "$db:" "$n_public" "${want_present:-none}" "${want_absent:-none}"

  # A positive find needs no control: it is self-evidencing.
  if [ -n "$found_forbidden" ]; then
    echo "        ASSERTION FAILED: $db holds relations that must not exist there:$found_forbidden"
    echo "        This is a statement about the DATABASE, not about the search."
    echo "        SCRUM-107 moved public_holiday to dcre_hcs, and account_type to"
    echo "        the mandates changelogs in dcre_man alone. account is a per-context"
    echo "        PROJECTION and belongs in dcre_col, dcre_pay and dcre_man, each"
    echo "        materialised by that context's own loader from the versioned"
    echo "        artifact, and nowhere else. A copy anywhere else is a second home"
    echo "        for one fact, and nothing at read time says which is stale."
    return 1
  fi

  if [ -n "$missing_present" ]; then
    if [ "$n_public" -eq 0 ]; then
      echo "        PENDING: expected relations absent ($missing_present ) and the"
      echo "        public schema is EMPTY, so no changelog has run against $db"
      echo "        yet. Nothing is concluded either way."
      return 3
    fi
    echo "        ASSERTION FAILED: $db is populated ($n_public relations) but is"
    echo "        missing relations it must own:$missing_present"
    return 1
  fi

  if [ -n "$want_absent" ] && [ -z "$found_control" ]; then
    echo "        PENDING: the content control found NONE of [$content_control]."
    echo "        Nothing known to belong in $db was found, so 'zero relations"
    echo "        named$want_absent' is the trivially true statement about an"
    echo "        empty database and proves nothing. Reported PENDING, not PASS."
    return 3
  fi

  if [ -n "$want_absent" ]; then
    echo "        control: found$found_control in $db, so the search demonstrably"
    echo "        works here and the absence of$want_absent counts as evidence."
  else
    echo "        control: found$found_control in $db."
  fi
  return 0
}

# Exit codes are identifiers, not a severity scale, so `worst` cannot be a plain
# numeric max: that would let PENDING (3) outrank a VIOLATION (1) and report the
# run as merely unfinished. Rank explicitly: clean < pending < unreadable <
# violation, and map back to the documented code.
SEVERITY=0   # 0 clean, 1 pending, 2 unreadable, 3 violation
rank_of() {
  case "$1" in
    0) echo 0 ;;
    3) echo 1 ;;
    2) echo 2 ;;
    1) echo 3 ;;
    *) echo 2 ;;   # an unrecognised status is "did not run", never a pass
  esac
}
code_of() {
  case "$1" in
    0) echo 0 ;;
    1) echo 3 ;;
    2) echo 2 ;;
    3) echo 1 ;;
  esac
}
note() {
  local r; r=$(rank_of "$1")
  [ "$r" -gt "$SEVERITY" ] && SEVERITY=$r
  return 0
}

run_audit() {
  local rc svc roster n_roster col_control
  SEVERITY=0

  # Derive the roster size rather than asserting it. The number that stood here
  # said 28 and the roster it described held 30, because a service was added and
  # the prose was not. A count that multiplies nothing is still read as a fact.
  roster="$SVC_COLLECTIONS $SVC_PAYMENTS $SVC_MANDATES $SVC_HOLIDAYS $SVC_SHARED"
  n_roster=$(printf '%s' "$roster" | wc -w | tr -d ' ')

  echo "[7/7] per-context isolation audit"
  echo "      universe A (prefix): public BASE TABLEs per database, matched"
  echo "      against the ${n_roster}-service prefix roster from the diagrams. rpt owns no"
  echo "      database and keeps its objects in the rpt SCHEMA, so it is never"
  echo "      counted as another context's object."
  echo "      universe B (placement): public relations, TABLES AND VIEWS, matched"
  echo "      by exact name. The relations SCRUM-107 moved carry no service"
  echo "      prefix, so universe A cannot see the move at all."

  audit_family_db dcre_col "$SVC_COLLECTIONS $SVC_SHARED" \
    "$SVC_PAYMENTS $SVC_MANDATES $SVC_HOLIDAYS" \
    "payments-mandates-holidays-or-accounts"; rc=$?
  note "$rc"

  audit_family_db dcre_pay "$SVC_PAYMENTS" \
    "$SVC_COLLECTIONS $SVC_MANDATES $SVC_HOLIDAYS" \
    "collections-mandates-holidays-or-accounts"; rc=$?
  note "$rc"

  audit_family_db dcre_man "$SVC_MANDATES" \
    "$SVC_COLLECTIONS $SVC_PAYMENTS $SVC_HOLIDAYS" \
    "collections-payments-holidays-or-accounts"; rc=$?
  note "$rc"

  # The one single-service shared-reference context. Every family prefix is
  # foreign in it.
  audit_family_db dcre_hcs "$SVC_HOLIDAYS" \
    "$SVC_COLLECTIONS $SVC_PAYMENTS $SVC_MANDATES" \
    "a-family"; rc=$?
  note "$rc"

  # agt_ops carries orchestrator state plus the rpt ops views. No stage service
  # of any family may own a table there, so every family prefix is foreign. Its
  # own roster is rpt only: AGT's own history table name is not asserted here,
  # because asserting a name this script has not verified would be a claim, not
  # a check.
  audit_family_db agt_ops "rpt" \
    "$SVC_COLLECTIONS $SVC_PAYMENTS $SVC_MANDATES $SVC_HOLIDAYS" \
    "stage-or-reference-service"; rc=$?
  note "$rc"

  # ---- universe B: relation placement --------------------------------------
  #
  # THE ASSERTION INVERTED ON 2026-08-09, AND THAT IS THE WHOLE POINT OF THE
  # WAVE. It used to read "account exists ONLY in dcre_acs", because there was
  # one shared table three contexts read across a database boundary. It now
  # reads "account exists in each of the three context databases, and in none of
  # the others", because there are three tables holding three different
  # PROJECTIONS of one immutable versioned artifact, each with its own family's
  # NOT NULL constraints. Three copies of a projection is not the two-homes
  # defect: nothing writes them but their own loader, each records the
  # dataset_version it consumed, and no context reads another's.
  #
  # The shapes are DELIBERATELY DIFFERENT and must not be reconciled. dcre_col
  # and dcre_pay carry the 17-column collections shape; dcre_man carries the
  # mandates shape plus account_type. A future audit that finds them unequal has
  # found the design, not a defect.
  #
  # Each database's content control is any of its OWN services' Liquibase
  # history tables: those are what it certainly holds once a changelog has run,
  # and if none is found the database is empty, so any absence would be
  # trivially true and is reported PENDING rather than PASS.
  col_control=""
  for svc in $SVC_COLLECTIONS; do
    col_control="$col_control ${svc}_databasechangelog"
  done
  assert_relation_placement dcre_col "account" "public_holiday account_type" \
    "$col_control"; rc=$?
  note "$rc"

  pay_control=""
  for svc in $SVC_PAYMENTS; do
    pay_control="$pay_control ${svc}_databasechangelog"
  done
  assert_relation_placement dcre_pay "account" "public_holiday account_type" \
    "$pay_control"; rc=$?
  note "$rc"

  # dcre_man is the ONLY database that holds account_type. It is a closed
  # vocabulary seeded by the mandates changelogs and is NOT part of the
  # artifact, so no loader touches it and the two collections-shape copies have
  # no business carrying it.
  man_control=""
  for svc in $SVC_MANDATES; do
    man_control="$man_control ${svc}_databasechangelog"
  done
  assert_relation_placement dcre_man "account account_type" "public_holiday" \
    "$man_control"; rc=$?
  note "$rc"

  # dcre_hcs holds public_holiday and NOT account. The control is public_holiday
  # itself plus the hcs history table. That is not circular: the want-present
  # check is evaluated FIRST and returns before the absence is judged, so by the
  # time "account is absent" is asserted, public_holiday has been CONFIRMED
  # present and is a relation genuinely known to be there.
  assert_relation_placement dcre_hcs "public_holiday" "account account_type" \
    "public_holiday hcs_databasechangelog"; rc=$?
  note "$rc"

  return "$(code_of "$SEVERITY")"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
overall=0

if [ "$audit_only" -eq 0 ]; then
  materialise_reference; rc_ref=$?
  if [ "$rc_ref" -ne 0 ]; then
    echo "--------------------------------------------------------------------------"
    echo "cutover HALTED at step 1, BEFORE the drop. NOTHING has been dropped and"
    echo "nothing has been scaled: the environment is exactly as it was found."
    echo "        materialise-account-reference.sh exited $rc_ref."
    echo "        A cutover without reference data is worse than no cutover: the"
    echo "        three loader jobs would find no artifact, every account lookup in"
    echo "        collections, payments and mandates would answer"
    echo "        FAIL_ACCOUNT_NOT_FOUND, and a deploy step that never ran would"
    echo "        read as a data-quality problem for as long as anybody believed it."
    exit "$rc_ref"
  fi

  quiesce
  drop_and_recreate; rc_drop=$?
  if [ "$rc_drop" -ne 0 ]; then
    echo "cutover ABORTED after the drop phase (that status belongs to"
    echo "drop_and_recreate, exit $rc_drop)."
    exit 2
  fi

  echo "[6/7] verifying the database roster with scripts/verify-databases.sh"
  rc_verify=0
  DCRE_NS="$NS" DCRE_CRDB_POD="$POD" bash "$HERE/verify-databases.sh" || rc_verify=$?
  echo "      verify-databases.sh exited $rc_verify (that status belongs to"
  echo "      verify-databases.sh, no pipeline is involved)"
  if [ "$rc_verify" -ne 0 ]; then
    echo "cutover ABORTED: the six databases are not all present."
    exit "$rc_verify"
  fi

  echo "      restarting AGT (it applies its own Liquibase to agt_ops on boot)"
  rc_scale=0
  kubectl scale deploy dcre-agt -n "$NS" --replicas=1 >/dev/null 2>&1 || rc_scale=$?
  if [ "$rc_scale" -ne 0 ]; then
    echo "      NOTE: kubectl scale up exited $rc_scale. AGT is NOT running."
  else
    rc_roll=0
    kubectl rollout status deploy/dcre-agt -n "$NS" --timeout=180s || rc_roll=$?
    echo "      kubectl rollout status exited $rc_roll (that status is the"
    echo "      rollout's)"
  fi
else
  echo "[1/7] materialising the account reference artifact: SKIPPED under"
  echo "      --audit-only, which is a read-only mode. Nothing is being recreated"
  echo "      and no family pipeline will run off this invocation, so staging"
  echo "      would be a write nobody asked for. Run the cutover proper, or"
  echo "      scripts/materialise-account-reference.sh on its own, to stage it."
  echo "[6/7] verifying the database roster with scripts/verify-databases.sh"
  rc_verify=0
  DCRE_NS="$NS" DCRE_CRDB_POD="$POD" bash "$HERE/verify-databases.sh" || rc_verify=$?
  echo "      verify-databases.sh exited $rc_verify"
  [ "$rc_verify" -ne 0 ] && exit "$rc_verify"
fi

run_audit; overall=$?

echo "--------------------------------------------------------------------------"
case "$overall" in
  0) echo "RESULT: every context database holds its own objects and no other"
     echo "        context's, and public_holiday / account / account_type are each"
     echo "        in exactly the one database that owns them. Version 1 schemas"
     echo "        were built by changesets that ran." ;;
  1) echo "RESULT: FAIL. A context database holds another context's objects, or a"
     echo "        moved relation is in the wrong database. The cutover did not"
     echo "        achieve isolation; see the VIOLATION and ASSERTION FAILED lines." ;;
  2) echo "RESULT: UNREADABLE. A query failed, so nothing was learned about"
     echo "        isolation. This is NOT a pass." ;;
  3) echo "RESULT: PENDING. Databases are present and empty of their own"
     echo "        service histories: no changelog has run yet. Drive a warm-up"
     echo "        round (scripts/env-reset.sh warm-up drops, or the e2e round),"
     echo "        then re-run: $0 --audit-only" ;;
esac
exit "$overall"
