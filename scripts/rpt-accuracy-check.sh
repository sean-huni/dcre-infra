#!/bin/zsh
# Accuracy matrix: independent raw-SQL derivation (root) vs rpt views (client role).
# Spec section 9 gate 4. Exit non-zero on any mismatch.
#
# Deviations from the plan brief (both required to make the checks actually execute/pass on CRDB):
#   1. SQL is a zsh ARRAY, not a scalar. A `SQL="kubectl ..."` scalar does NOT word-split under
#      #!/bin/zsh, so `$SQL -e ...` would try to exec the whole string as one command name and fail.
#   2. percentile_cont needs an explicit ::FLOAT8 cast on CockroachDB (no DECIMAL overload -> 42883).
#      The views cast internally (ORDER BY amount::FLOAT8); the raw side casts identically so both
#      sides produce the same FLOAT8 value and compare exactly.
set -e
cd "$(dirname "$0")/.."
SQL=(kubectl -n dcre exec crdb-0 -- ./cockroach sql --insecure --format=csv --database=dcre_collections)
fail=0
check() {  # label, expected_sql(root, raw), actual_sql(role, view), role
  local label=$1 esql=$2 asql=$3 role=$4
  local e=$("${SQL[@]}" -e "$esql" | tail -1)
  local a=$("${SQL[@]}" --user=$role -e "$asql" | tail -1)
  if [[ "$e" == "$a" ]]; then echo "PASS: $label ($e)"
  else echo "FAIL: $label expected=$e actual=$a"; fail=1; fi
}

for C in FNBCC01 FNBCC02 FNBRF01; do
  R=${C:l}
  check "$C total settled amount" \
    "SELECT COALESCE(sum(t.amount),0) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id JOIN (SELECT DISTINCT ON (e2e) e2e,status FROM pbsr_resp ORDER BY e2e,created_at DESC) p ON p.e2e=t.e2e WHERE h.client_token='$C' AND p.status='ACSC'" \
    "SELECT COALESCE(sum(settled_amount),0) FROM rpt.v_tx_daily" "$R"
  check "$C tx count" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_tx_daily" "$R"
  check "$C PBSR reject count" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id JOIN (SELECT DISTINCT ON (e2e) e2e,status FROM pbsr_resp ORDER BY e2e,created_at DESC) p ON p.e2e=t.e2e WHERE h.client_token='$C' AND p.status='RJCT'" \
    "SELECT COALESCE(sum(fail_count),0) FROM rpt.v_reason_daily WHERE stage='PBSR'" "$R"
  check "$C funnel SETTLED" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id JOIN (SELECT DISTINCT ON (e2e) e2e,status FROM pbsr_resp ORDER BY e2e,created_at DESC) p ON p.e2e=t.e2e WHERE h.client_token='$C' AND p.status='ACSC'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_funnel_daily WHERE stage='SETTLED'" "$R"
  check "$C recon control sum" \
    "SELECT COALESCE(sum(cm.amount),0) FROM crw_emission_member cm JOIN crw_emission ce ON ce.id=cm.emission_id JOIN tx_header h ON h.arrival_id=ce.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(control_sum),0) FROM rpt.v_recon_daily" "$R"
  check "$C p95 amount" \
    "SELECT percentile_cont(0.95::FLOAT8) WITHIN GROUP (ORDER BY t.amount::FLOAT8) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT percentile_cont(0.95::FLOAT8) WITHIN GROUP (ORDER BY amount::FLOAT8) FROM rpt.v_tx" "$R"
  check "$C bucket total tx" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_amount_buckets" "$R"
done

# cross-client integrity: sum of per-client views == internal total
tot_i=$("${SQL[@]}" --user=rpt_internal -e "SELECT COALESCE(sum(total_amount),0) FROM rpt.v_tx_daily" | tail -1)
tot_r=$("${SQL[@]}" -e "SELECT COALESCE(sum(amount),0) FROM tx_entry" | tail -1)
[[ "$tot_i" == "$tot_r" ]] && echo "PASS: internal total == raw total ($tot_i)" || { echo "FAIL: internal $tot_i raw $tot_r"; fail=1; }

exit $fail
