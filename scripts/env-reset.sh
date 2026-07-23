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

echo "[1/13] stop AGT first (watcher/reconciler/clocks must not write to a dropped DB)"
kubectl scale deploy dcre-agt -n $NS --replicas=0
kubectl wait --for=delete pod -l app=dcre-agt -n $NS --timeout=90s 2>/dev/null || true

echo "[2/13] delete all Jobs and stage pods across control + flow namespaces"
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

echo "[3/13] stop fint-sim (a stale pre-restructure sim survives resets and keeps"
echo "       writing the old flat paths; a fresh one restarts in step 13)"
pkill -f fint-sim 2>/dev/null || true

echo "[4/13] drop + recreate all three databases"
kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -e "
  DROP DATABASE IF EXISTS dcre_col CASCADE;
  DROP DATABASE IF EXISTS agt_ops CASCADE;
  DROP DATABASE IF EXISTS dcre_man CASCADE;
  CREATE DATABASE dcre_col;
  CREATE DATABASE agt_ops;
  CREATE DATABASE dcre_man;"

echo "[5/13] drain async schema-change jobs (DROP ... CASCADE returns while its jobs"
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

echo "[6/13] pre-seed Liquibase history+lock tables, ONLY after the drain"
echo "       (first-run bootstrap-race guard; idempotent IF NOT EXISTS)"
kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_col \
  < $INFRA/scripts/seed-liquibase-history.sql > /dev/null
echo "       apply the CANONICAL dcre_man shared-core DDL+seed (seed-man-core.sql;"
echo "       services' MARK_RAN 000 bootstraps converge on it in any boot order)"
kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_man \
  < $INFRA/scripts/seed-man-core.sql > /dev/null
typeset -i cguard=0
while :; do
  mct=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM dcre_man] WHERE table_name IN ('account_type','account','mandate','mandate_reason_code');") || mct=""
  [[ "$mct" == "4" ]] && break
  cguard+=1
  if (( cguard > 6 )); then
    echo "ERROR: expected 4 dcre_man shared-core tables (account_type, account, mandate, mandate_reason_code), found ${mct:-0}." >&2
    echo "       NOT scaling AGT up: an M-service bootstrapping now would race the shared-core mint." >&2
    exit 1
  fi
  sleep 5
done
echo "       dcre_man shared-core: 4 core tables present"

echo "[7/13] verify all 44 history+lock tables exist BEFORE any service comes back"
echo "       (24 dcre_col + 18 dcre_man + 2 agt_ops; per-database guards below)"
typeset -i vguard=0
while :; do
  lbt=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM dcre_col] WHERE table_name LIKE '%databasechangelog%';") || lbt=""
  [[ "$lbt" == "24" ]] && break
  vguard+=1
  if (( vguard > 6 )); then
    echo "ERROR: expected 24 Liquibase history+lock tables in dcre_col, found ${lbt:-0}." >&2
    echo "       NOT scaling AGT up: a service bootstrapping Liquibase now would race the seed." >&2
    exit 1
  fi
  sleep 5
done
typeset -i mguard=0
while :; do
  mbt=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM dcre_man] WHERE table_name LIKE '%databasechangelog%';") || mbt=""
  [[ "$mbt" == "18" ]] && break
  mguard+=1
  if (( mguard > 6 )); then
    echo "ERROR: expected 18 Liquibase history+lock tables in dcre_man, found ${mbt:-0}." >&2
    echo "       NOT scaling AGT up: a service bootstrapping Liquibase now would race the seed." >&2
    exit 1
  fi
  sleep 5
done
typeset -i rguard=0
while :; do
  rbt=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM agt_ops] WHERE table_name LIKE 'rpt_databasechangelog%';") || rbt=""
  [[ "$rbt" == "2" ]] && break
  rguard+=1
  if (( rguard > 6 )); then
    echo "ERROR: expected 2 rpt Liquibase history+lock tables in agt_ops, found ${rbt:-0}." >&2
    echo "       NOT scaling AGT up: a service bootstrapping Liquibase now would race the seed." >&2
    exit 1
  fi
  sleep 5
done

echo "[8/13] clean exchange dirs, per-client tree (find -delete: zsh glob rm aborts on"
echo "       empty dirs; tracked .gitkeep files are kept)"
for base in $CLIENTS; do
  find $EX/$base -type f ! -name '.gitkeep' -delete 2>/dev/null || true
done
find $EX/outcomes -type f ! -name '.gitkeep' -delete 2>/dev/null || true
rm -f $EX/.reset-stamp

echo "[9/13] restart AGT (applies its Liquibase, watcher+clocks resume)"
kubectl scale deploy dcre-agt -n $NS --replicas=1
kubectl rollout status deploy/dcre-agt -n $NS --timeout=120s

echo "[10/13] reference seed BEFORE warm-up (seed DDL creates account/mandate;\n        AIS 000-bootstrap only guards ordering and runs far too late for warm-up)"
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

echo "[11/13] warm-up drops: one tiny file per route so every service's Liquibase"
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
  echo "WARN: no --seed given; account/mandate do not exist until a seed or AIS runs." >&2
  echo "      CTV warm-up will TECH-fail (relation account does not exist) until then." >&2
fi

echo "[12/13] post-checks + reset stamp"
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
kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -d dcre_col --format=csv -e "
  SELECT (SELECT count(*) FROM account) accounts, (SELECT count(*) FROM mandate) mandates;"
date +%s > $EX/.reset-stamp
echo "        reset stamp written: $EX/.reset-stamp ($(cat $EX/.reset-stamp))"

echo "[13/13] restart fint-sim (nohup, background; consumes per-client fint-req/out)"
nohup $INFRA/scripts/fint-sim.sh > /tmp/fint-sim.log 2>&1 &
disown
echo "        fint-sim pid $!, log /tmp/fint-sim.log"

echo "env-reset complete: fleet untouched, DBs fresh, exchange clean, fint-sim fresh"
