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
# does NOT seed a changelog. It drops, it recreates four empty databases, and
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
#   0  cutover done, and every family database holds its own objects and no
#      other family's
#   1  a real violation: a database is absent, or a family database holds
#      another family's objects
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

# One database per family, never shared. agt_ops is orchestrator state.
DATABASES="agt_ops dcre_col dcre_man dcre_pay"

# The service roster IS the diagrams (design-register R-49; scripts/verify-topology.sh).
# PRG IS THE PAYMENTS REPORT GENERATOR; the collections one is CRG. Read every
# occurrence in context: a find-and-replace on this token yields a file that
# parses and is semantically inverted.
SVC_COLLECTIONS="crr ctv cde crw cir cix csx cpx crg"
SVC_PAYMENTS="prr ptv pai prw pir pix psx ppx prg"
SVC_MANDATES="mrr mrv mas mit mir mrw mix msx mpx mrg"
# Cross-family: on no family sheet, so never counted as another family's object.
SVC_SHARED="hcs rpt"

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
      echo "                        per-family isolation audit and report."
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
csv_body() { printf '%s' "${1#*$'\n'}"; }

# ---------------------------------------------------------------------------
# Phase 1: quiesce. AGT must be down and stage Jobs gone before the drop, or a
# watcher/clock writes into a database that is being dropped and the drop's own
# schema-change jobs collide with a half-created table.
# ---------------------------------------------------------------------------
quiesce() {
  local rc

  echo "[1/6] scaling AGT to 0 (watcher, reconciler and clocks must not write"
  echo "      into a database that is being dropped)"
  rc=0; kubectl scale deploy dcre-agt -n "$NS" --replicas=0 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "      NOTE: kubectl scale exited $rc (deployment absent?). Continuing:"
    echo "      an absent AGT is already quiesced. This status belongs to the"
    echo "      scale command, not to anything below it."
  fi
  rc=0; kubectl wait --for=delete pod -l app=dcre-agt -n "$NS" --timeout=90s >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && echo "      NOTE: kubectl wait exited $rc; proceeding."

  echo "[2/6] deleting stage Jobs and pods in the flow namespaces"
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

  echo "[3/6] dropping and recreating: $DATABASES"
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

  echo "[4/6] draining CockroachDB schema-change jobs (DROP ... CASCADE returns"
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
# Phase 3: the per-family isolation audit.
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
  control="$(printf '%s' "${REPLY_CSV#*$'\n'}" | tr -d '\r\n ')"
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
  body="${REPLY_CSV#*$'\n'}"
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
  local rc
  SEVERITY=0
  echo "[6/6] per-family isolation audit"
  echo "      universe: public BASE TABLEs per database, matched against the"
  echo "      28-service prefix roster from the diagrams. hcs and rpt are"
  echo "      cross-family and are never counted as a foreign family's objects."

  audit_family_db dcre_col "$SVC_COLLECTIONS $SVC_SHARED" \
    "$SVC_PAYMENTS $SVC_MANDATES" "payments-or-mandates"; rc=$?
  note "$rc"

  audit_family_db dcre_pay "$SVC_PAYMENTS" \
    "$SVC_COLLECTIONS $SVC_MANDATES" "collections-or-mandates"; rc=$?
  note "$rc"

  audit_family_db dcre_man "$SVC_MANDATES" \
    "$SVC_COLLECTIONS $SVC_PAYMENTS" "collections-or-payments"; rc=$?
  note "$rc"

  # agt_ops carries orchestrator state plus the rpt ops views. No stage service
  # of any family may own a table there, so every family prefix is foreign. Its
  # own roster is rpt only: AGT's own history table name is not asserted here,
  # because asserting a name this script has not verified would be a claim, not
  # a check.
  audit_family_db agt_ops "rpt" \
    "$SVC_COLLECTIONS $SVC_PAYMENTS $SVC_MANDATES" "stage-service"; rc=$?
  note "$rc"

  return "$(code_of "$SEVERITY")"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
overall=0

if [ "$audit_only" -eq 0 ]; then
  quiesce
  drop_and_recreate; rc_drop=$?
  if [ "$rc_drop" -ne 0 ]; then
    echo "cutover ABORTED after the drop phase (that status belongs to"
    echo "drop_and_recreate, exit $rc_drop)."
    exit 2
  fi

  echo "[5/6] verifying the database roster with scripts/verify-databases.sh"
  rc_verify=0
  DCRE_NS="$NS" DCRE_CRDB_POD="$POD" bash "$HERE/verify-databases.sh" || rc_verify=$?
  echo "      verify-databases.sh exited $rc_verify (that status belongs to"
  echo "      verify-databases.sh, no pipeline is involved)"
  if [ "$rc_verify" -ne 0 ]; then
    echo "cutover ABORTED: the four databases are not all present."
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
  echo "[5/6] verifying the database roster with scripts/verify-databases.sh"
  rc_verify=0
  DCRE_NS="$NS" DCRE_CRDB_POD="$POD" bash "$HERE/verify-databases.sh" || rc_verify=$?
  echo "      verify-databases.sh exited $rc_verify"
  [ "$rc_verify" -ne 0 ] && exit "$rc_verify"
fi

run_audit; overall=$?

echo "--------------------------------------------------------------------------"
case "$overall" in
  0) echo "RESULT: every family database holds its own objects and no other"
     echo "        family's. Version 1 schemas were built by changesets that ran." ;;
  1) echo "RESULT: FAIL. A family database holds another family's objects. The"
     echo "        cutover did not achieve isolation; see the VIOLATION lines." ;;
  2) echo "RESULT: UNREADABLE. A query failed, so nothing was learned about"
     echo "        isolation. This is NOT a pass." ;;
  3) echo "RESULT: PENDING. Databases are present and empty of their own"
     echo "        service histories: no changelog has run yet. Drive a warm-up"
     echo "        round (scripts/env-reset.sh warm-up drops, or the e2e round),"
     echo "        then re-run: $0 --audit-only" ;;
esac
exit "$overall"
