#!/bin/zsh
# DCRE full environment reset (clean slate for a fresh test round).
# Distilled from the 2026-07-13 chaos-cycle teardown; hardened 2026-07-14 after the
# per-client live failures (flat warm-up paths, CRDB drop-job race behind the
# "relation ..._databasechangelog already exists" class, stale fint-sim).
# Ordering is load-bearing, see the numbered comments. Invoked by /dcre-reset.
#
# Usage:
#   env-reset.sh                  # reset infra + schema warm-up, keep no seed
#   env-reset.sh --seed <accounts.sql> <mandates.sql>   # also reseed reference data
#
# NEVER deletes the crdb PVC (data-crdb-0) or the crdb pod's statefulset.
set -euo pipefail
NS=dcre
INFRA=${0:a:h:h}
EX=$INFRA/exchange
CLIENTS=(fnbcc01 fnbcc02 fnbrf01)

SEED_ACCOUNTS="" SEED_MANDATES=""
if [[ "${1:-}" == "--seed" ]]; then
  SEED_ACCOUNTS=$2; SEED_MANDATES=$3
fi

# single-value SQL helper: sqlval <sql> [db]
sqlval() {
  local db=(); [[ -n "${2:-}" ]] && db=(-d "$2")
  kubectl exec -n $NS crdb-0 -- cockroach sql --insecure $db --format=tsv -e "$1" \
    2>/dev/null | tail -1 | tr -d '[:space:]'
}

echo "[1/12] stop AGT first (watcher/reconciler/clocks must not write to a dropped DB)"
kubectl scale deploy dcre-agt -n $NS --replicas=0
kubectl wait --for=delete pod -l app=dcre-agt -n $NS --timeout=90s 2>/dev/null || true

echo "[2/12] delete all Jobs and stage pods across control + flow namespaces"
echo "       (SCRUM-70: stage Jobs live in dcre-col/dcre-pay/dcre-man; crdb-0 in"
echo "       $NS is NOT dcre-* prefixed: kept)"
for ns in dcre dcre-col dcre-pay dcre-man; do
  if [[ $ns == "$NS" ]]; then
    kubectl delete jobs -n $ns --all --wait=false
    kubectl get pods -n $ns --no-headers | awk '$1 ~ /^dcre-/ {print $1}' \
      | xargs -r kubectl delete pod -n $ns --wait=false --grace-period=0
  else
    # Flow namespaces hold nothing but stage Jobs/pods; tolerate a cluster
    # that predates the SCRUM-70 kustomize apply (namespace absent).
    kubectl delete jobs -n $ns --all --wait=false 2>/dev/null || true
    kubectl delete pods -n $ns --all --wait=false --grace-period=0 2>/dev/null || true
  fi
done

echo "[3/12] stop fint-sim (a stale pre-restructure sim survives resets and keeps"
echo "       writing the old flat paths; a fresh one restarts in step 12)"
pkill -f fint-sim 2>/dev/null || true

echo "[4/12] drop + recreate all four databases"
# SCRUM-107: dcre_pay joins the reset. A database that escapes the reset is worse
# than one that is missing: the collections databases come back empty while stale
# payments rows survive, so a "clean slate" run is quietly not clean.
# --database=defaultdb is EXPLICIT and load-bearing: defaultdb is the one database
# not being dropped, and a defaulted connection database is how 22 Liquibase
# history tables once landed somewhere nobody was looking while the verify step
# correctly found zero.
kubectl exec -n $NS crdb-0 -- cockroach sql --insecure --database=defaultdb -e "
  DROP DATABASE IF EXISTS dcre_col CASCADE;
  DROP DATABASE IF EXISTS agt_ops CASCADE;
  DROP DATABASE IF EXISTS dcre_man CASCADE;
  DROP DATABASE IF EXISTS dcre_pay CASCADE;
  CREATE DATABASE dcre_col;
  CREATE DATABASE agt_ops;
  CREATE DATABASE dcre_man;
  CREATE DATABASE dcre_pay;"

echo "[5/12] drain async schema-change jobs (DROP ... CASCADE returns while its jobs"
echo "       still run: 'NOTICE: waiting for job(s) to complete'; seeding or scaling"
echo "       into that window collides with half-materialized metadata)"
# SCHEMA CHANGE GC excluded: it only reclaims data ranges later and can linger.
typeset -i drain=0
while :; do
  pending=$(sqlval "SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE','NEW SCHEMA CHANGE') AND status IN ('pending','running');") || pending=""
  [[ "$pending" == "0" ]] && break
  drain+=1
  if (( drain > 24 )); then
    echo "WARN: schema-change jobs still not drained after 120s (pending=${pending:-?}); continuing" >&2
    break
  fi
  sleep 5
done

echo "[6/12] apply the CANONICAL dcre_man shared-core DDL+seed (seed-man-core.sql;"
echo "       services' MARK_RAN 000 bootstraps converge on it in any boot order)"
# SCRUM-107 v1 cutover: seed-liquibase-history.sql is DELETED and no longer applied
# here. It pre-created every module's Liquibase history+lock tables so a fresh
# database already had them, which is precisely the "hacking around the liquibase
# scripts" the owner ruled out on 2026-08-08. On version 1 there is no history to
# seed: every table is minted by a changeset that actually ran, or it does not
# exist.
#
# WHAT THAT GIVES BACK, stated plainly rather than dropped quietly: the file
# existed to stop concurrent FIRST runs of the SAME service racing on
# CREATE TABLE <svc>_databasechangelog, because the lock table does not exist yet
# and so nothing serialises the bootstrap. The loser crashes with
# "relation already exists" (M7 straight-cycle e2e, 2026-07-13). That race is now
# unguarded here. The correct home for the fix is each service's own changelog
# (Liquibase's own lock, or a first-run warm-up that runs each stage once
# serially before parallel traffic), NOT infra pre-creating the table. See the
# cutover report; this is an owner decision, not one to paper over here.
#
# OPEN, SAME CLASS: seed-man-core.sql below still pre-applies shared-core DDL that
# the mandates services' MARK_RAN 000 bootstraps then skip. It is left in place
# because removing it needs the owning changelogs in the mandates repos to take
# the tables over, which is a change in those repos, not in infra.
kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_man \
  < $INFRA/scripts/seed-man-core.sql > /dev/null
typeset -i cguard=0
while :; do
  # SCRUM-91: the mandate projection is no longer a shared-core table (MSR deleted,
  # state derived by the MRG views), so the core is three tables, not four.
  mct=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM dcre_man] WHERE table_name IN ('account_type','account','mandate_reason_code');") || mct=""
  [[ "$mct" == "3" ]] && break
  cguard+=1
  if (( cguard > 6 )); then
    echo "ERROR: expected 3 dcre_man shared-core tables (account_type, account, mandate_reason_code), found ${mct:-0}." >&2
    echo "       NOT scaling AGT up: an M-service bootstrapping now would race the shared-core mint." >&2
    exit 1
  fi
  sleep 5
done
echo "       dcre_man shared-core: 3 core tables present"

# The 46-history-table verification that stood here is GONE with the seed it
# verified. It asserted that dcre_col held 24, dcre_man 20 and agt_ops 2 Liquibase
# history+lock tables BEFORE any service returned. Nothing pre-creates those
# tables on version 1, so the assertion could only ever have failed, and an
# assertion that cannot pass is not a stricter gate, it is a broken reset.
#
# It is NOT replaced by a weaker version of itself. The property it was really
# guarding (each family database holds its own objects and no other family's) is
# now asserted AFTER the services have run, by scripts/cutover-v1.sh --audit-only,
# where the tables actually exist and where a foreign-family table is a finding
# rather than a race.

echo "[7/12] clean exchange dirs, per-client tree (find -delete: zsh glob rm aborts on"
echo "       empty dirs; tracked .gitkeep files are kept)"
for base in $CLIENTS; do
  find $EX/$base -type f ! -name '.gitkeep' -delete 2>/dev/null || true
done
find $EX/outcomes -type f ! -name '.gitkeep' -delete 2>/dev/null || true
rm -f $EX/.reset-stamp

echo "[8/12] restart AGT (applies its Liquibase, watcher+clocks resume)"
kubectl scale deploy dcre-agt -n $NS --replicas=1
kubectl rollout status deploy/dcre-agt -n $NS --timeout=120s

echo "[9/12] reference seed BEFORE warm-up: the seed DDL is what creates"
echo "        dcre_col.account and dcre_col.mandate. NOTHING in version control"
echo "        mints them since the 2026-08-08 rename retired ais (it became the"
echo "        PAYMENTS service pai and left collections entirely), so the R-04"
echo "        single-writer of dcre_col.account is currently UNASSIGNED. Do not"
echo "        infer an owner from this comment: --seed is the only path today."
if [[ -n "$SEED_ACCOUNTS" ]]; then
  for f in $SEED_ACCOUNTS $SEED_MANDATES; do
    [[ -f $f ]] || { echo "ERROR: seed file not found: $f" >&2; exit 1; }
  done
  echo "        seeding accounts from $SEED_ACCOUNTS ($(wc -l < $SEED_ACCOUNTS | tr -d ' ') lines; large seeds take minutes)..."
  kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure -d dcre_col < $SEED_ACCOUNTS > /dev/null
  echo "        accounts file done: $(sqlval 'SELECT count(*) FROM account;' dcre_col) rows in account"
  echo "        seeding mandates from $SEED_MANDATES ($(wc -l < $SEED_MANDATES | tr -d ' ') lines)..."
  kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure -d dcre_col < $SEED_MANDATES > /dev/null
  echo "        mandates file done: $(sqlval 'SELECT count(*) FROM mandate;' dcre_col) rows in mandate"
else
  echo "        skipped (no --seed): load accounts/mandates SQL before real fixtures"
fi

echo "[10/12] warm-up drops: one tiny file per route so every service's Liquibase"
echo "        recreates its tables (files NACK against a fresh seed: expected, harmless)"
WARM_REQ_IN=$EX/fnbrf01/onhost-req/in
WARM_ENDO_IN=$EX/fnbrf01/onhost-req-endo/in
for d in $WARM_REQ_IN $WARM_ENDO_IN; do
  if [[ ! -d $d ]]; then
    echo "ERROR: warm-up target $d missing." >&2
    echo "       Fixtures are FNBRF01_*; per-client layout (SCRUM-42) is exchange/<clientbase>/<route>/in/." >&2
    echo "       Restore the per-client exchange tree (git checkout dcre-infra exchange/) and re-run." >&2
    exit 1
  fi
done
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120010002.txt $WARM_REQ_IN/
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120020002.txt $WARM_ENDO_IN/
if [[ -n "$SEED_ACCOUNTS" ]]; then
  echo "        verifying account/mandate exist (created by the seed DDL in step 10)..."
  typeset -i guard=0
  until kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -d dcre_col \
        -e "SELECT 1 FROM account LIMIT 1; SELECT 1 FROM mandate LIMIT 1;" >/dev/null 2>&1; do
    sleep 10; guard+=1
    (( guard > 60 )) && { echo "ERROR: reference tables missing after 10min despite seed" >&2; exit 1; }
  done
else
  echo "WARN: no --seed given; dcre_col.account and dcre_col.mandate do not exist" >&2
  echo "      at all. Their former minter (ais) is retired, so --seed is the only" >&2
  echo "      path that creates them." >&2
  echo "      CTV warm-up will TECH-fail (relation account does not exist) until then." >&2
fi

echo "[11/12] post-checks + reset stamp"
typeset -i hguard=0
ph=""
while :; do
  ph=$(sqlval "SELECT count(*) FROM public_holiday;" dcre_col) || ph=""
  [[ -n "$ph" && "$ph" != "0" ]] && break
  hguard+=1
  (( hguard > 12 )) && break
  sleep 5
done
if [[ -z "$ph" || "$ph" == "0" ]]; then
  echo "WARN: public_holiday is EMPTY (HCS re-sync expected ~10s after AGT up); CDE fail-closes without it" >&2
else
  echo "        public_holiday: $ph rows (HCS re-synced)"
fi
so=$(sqlval "SELECT count(*) FROM stage_outcome;" dcre_col) || so=""
echo "        stage_outcome baseline: ${so:-n/a} rows. Transient CRW TECH_FAILED clock"
echo "        windows between AGT-up and the first CDE run (minting cde_schedule) are"
echo "        EXPECTED; subtract this baseline in later pass-rate accounting."
# Reference-data census. Both tables live in dcre_col: `mandate` here is the LEGACY
# collections mandate table (kept until M11), NOT the dcre_man projection that
# SCRUM-91 dropped. Do not "fix" this to point at dcre_man.
#
# Degrades to a WARN instead of aborting the reset. Without --seed neither table
# exists until --seed loads it, and step 10 already prints that warning
# itself, so a bare query here made the script fail on the very condition it had
# just predicted. A post-CHECK must never be the thing that kills the reset.
acct=$(sqlval "SELECT count(*) FROM account;" dcre_col) || acct=""
mndt=$(sqlval "SELECT count(*) FROM mandate;" dcre_col) || mndt=""
if [[ -z "$acct" || -z "$mndt" ]]; then
  echo "WARN: reference data absent (accounts=${acct:-n/a} mandates=${mndt:-n/a}); account/mandate" >&2
  echo "      are minted ONLY by --seed since ais retired. CTV gating stays fail-closed until then." >&2
else
  echo "        reference data: $acct accounts, $mndt mandates"
fi
date +%s > $EX/.reset-stamp
echo "        reset stamp written: $EX/.reset-stamp ($(cat $EX/.reset-stamp))"

echo "[12/12] restart fint-sim (nohup, background; consumes per-client fint-req/out)"
nohup $INFRA/scripts/fint-sim.sh > /tmp/fint-sim.log 2>&1 &
disown
echo "        fint-sim pid $!, log /tmp/fint-sim.log"

echo "env-reset complete: fleet untouched, DBs fresh, exchange clean, fint-sim fresh"
