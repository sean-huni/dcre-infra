#!/bin/zsh
# DCRE full environment reset (clean slate for a fresh test round).
# Distilled from the 2026-07-13 chaos-cycle teardown; ordering is load-bearing,
# see the numbered comments. Invoked by the project skill /dcre-reset.
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

SEED_ACCOUNTS="" SEED_MANDATES=""
if [[ "${1:-}" == "--seed" ]]; then
  SEED_ACCOUNTS=$2; SEED_MANDATES=$3
fi

echo "[1/8] stop AGT first (watcher/reconciler/clocks must not write to a dropped DB)"
kubectl scale deploy dcre-agt -n $NS --replicas=0
kubectl wait --for=delete pod -l app=dcre-agt -n $NS --timeout=90s 2>/dev/null || true

echo "[2/8] delete all Jobs and dcre-* pods (crdb-0 is NOT dcre-* prefixed: kept)"
kubectl delete jobs -n $NS --all --wait=false
kubectl get pods -n $NS --no-headers | awk '$1 ~ /^dcre-/ {print $1}' \
  | xargs -r kubectl delete pod -n $NS --wait=false --grace-period=0

echo "[3/8] drop + recreate both databases"
kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -e "
  DROP DATABASE IF EXISTS dcre_collections CASCADE;
  DROP DATABASE IF EXISTS agt_ops CASCADE;
  CREATE DATABASE dcre_collections;
  CREATE DATABASE agt_ops;"

echo "[4/8] pre-seed Liquibase history+lock tables (first-run bootstrap-race guard)"
kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure \
  < $INFRA/scripts/seed-liquibase-history.sql > /dev/null

echo "[5/8] clean exchange dirs (find -delete: zsh glob rm aborts on empty dirs)"
for d in onhost-req onhost-req-endo onhost-resp outcomes fint-req fint-resp error archive; do
  find $EX/$d -type f -delete 2>/dev/null || true
done

echo "[6/8] restart AGT (applies its Liquibase, watcher+clocks resume)"
kubectl scale deploy dcre-agt -n $NS --replicas=1
kubectl rollout status deploy/dcre-agt -n $NS --timeout=120s

echo "[7/8] warm-up drops: one tiny file per route so every service's Liquibase"
echo "      recreates its tables (files NACK against a fresh seed: expected, harmless)"
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120010002.txt $EX/onhost-req/
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120020002.txt $EX/onhost-req-endo/
echo "      waiting for CTV's first run to create account/mandate tables..."
typeset -i guard=0
until kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -d dcre_collections \
      -e "SELECT 1 FROM account LIMIT 1; SELECT 1 FROM mandate LIMIT 1;" >/dev/null 2>&1; do
  sleep 10; guard+=1
  (( guard > 60 )) && { echo "ERROR: reference tables not created after 10min" >&2; exit 1; }
done

echo "[8/8] reference seed"
if [[ -n "$SEED_ACCOUNTS" ]]; then
  kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure -d dcre_collections < $SEED_ACCOUNTS > /dev/null
  kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure -d dcre_collections < $SEED_MANDATES > /dev/null
  echo "      seeded from $SEED_ACCOUNTS + $SEED_MANDATES"
else
  echo "      skipped (no --seed): load accounts/mandates SQL before real fixtures"
fi

kubectl exec -n $NS crdb-0 -- cockroach sql --insecure -d dcre_collections --format=csv -e "
  SELECT (SELECT count(*) FROM account) accounts, (SELECT count(*) FROM mandate) mandates;"
echo "env-reset complete: fleet untouched, DBs fresh, exchange clean"
