#!/bin/zsh
# Accuracy matrix: raw-SQL derivation (root, from BASE tables only) vs the rpt views the T13
# Grafana dashboards actually display (queried as the appropriate client / internal role).
# Independence caveat: the correlation-sensitive checks MIRROR the views' binding rules; see the
# EFF honesty note below for which checks are logic mirrors vs independent recomputation.
# Spec section 9 gate 4. Exit non-zero on any mismatch. This is an archived evidence artifact, so it
# is fail-CLOSED: a check FAILS (never silently PASSES) if either side is empty or non-numeric.
#
# Directly verified grains (raw BASE-table derivation vs the named view/column, per client unless noted):
#   rpt.v_tx_daily        - total settled_amount; tx_count; internal-total integrity (all clients)
#   rpt.v_tx              - p95 amount (percentile_cont, ::FLOAT8 both sides)
#   rpt.v_debtor_daily    - total failed_count; top debtor failed_amount (max over debtor/day sums)
#   rpt.v_cure            - actually-cured count (days_to_cure IS NOT NULL); the panel's median-days
#                           -to-cure is empty when this is 0, so 0==0 verifies that empty is correct
#   rpt.v_funnel_daily    - ALL FOUR stages: SUBMITTED, CTV_PASS, EMITTED, SETTLED tx_count
#   rpt.v_recon_daily     - control_sum; settled_sum; variance
#   rpt.v_amount_buckets  - total tx_count; modal-bucket (E_5K_PLUS) count -> catches boundary misclass
#   rpt.v_reason_daily    - ISR/SBSR/PBSR terminal-non-success counts; CTV-stage fail_count
#   agt_ops rpt.v_ops_stage_health - business_count total; tech_failed_count total (internal ops board)
#
# Deviations from the plan brief (all required to make the checks execute/pass/have-teeth on live CRDB):
#   1. SQL is a zsh ARRAY, not a scalar. A `SQL="kubectl ..."` scalar does NOT word-split under
#      #!/bin/zsh, so `$SQL -e ...` would try to exec the whole string as one command name and fail.
#   2. percentile_cont needs an explicit ::FLOAT8 cast on CockroachDB (no DECIMAL overload -> 42883).
#      The views cast internally (ORDER BY amount::FLOAT8); the raw side casts identically so both
#      sides produce the same FLOAT8 value and compare exactly.
#   3. The brief expected v_cure count == 0 assuming one process_date. Reality: FNBRF01 spans two
#      process_dates and v_cure is a LEFT JOIN, so `count(*)` returns every fail row (50/50/35), NOT 0.
#      The cure PANEL is median-days-to-cure over `days_to_cure IS NOT NULL`; verifying its empty state
#      means counting ACTUALLY-CURED rows, which is 0 on both sides (no failed debtor was later settled)
#      - so this check asserts the cured count, which is the honest 0==0 the brief intended.
set -e
cd "$(dirname "$0")/.."
SQL=(kubectl -n dcre exec crdb-0 -- ./cockroach sql --insecure --format=csv --database=dcre_col)
SQLO=(kubectl -n dcre exec crdb-0 -- ./cockroach sql --insecure --format=csv --database=agt_ops)
fail=0
num='^-?[0-9]+(\.[0-9]+)?$'   # integer/decimal, optional leading minus

# Per-tx effective status + process_date, rebuilt from BASE tables with the SAME correlation rules
# the corrected views encode. HONESTY NOTE: because this CTE re-encodes those rules, every check
# built on it is a LOGIC MIRROR of the correlation-sensitive views: it verifies tenancy scoping and
# aggregation coverage, not the binding rules themselves. Genuinely independent recomputation is
# limited to the checks that read base tables WITHOUT this CTE AND without re-encoding a corrected
# rule: tx counts, CTV fail counts, funnel SUBMITTED/CTV_PASS, recon control_sum, p95, bucket
# counts, the ops checks and the internal-total integrity check. Funnel EMITTED is ALSO a logic
# mirror: its raw side re-encodes the corrected (arrival_id,sequence,e2e) member-binding predicate
# even though it skips this CTE.
# Mirrored rules: the CURRENT emission per (arrival_id,sequence,e2e) is the latest
# (run_date,batch_ordinal); resolved rows bind by (emission_id,e2e); legacy NULL-emission rows bind
# ONLY via crw_emission.outbound_msg_id=orgnl_msg_id (fail-closed: rows with neither identity are
# excluded; there is NO parent MsgId-family fallback). Within a leg, resolved rows outrank legacy
# twins, then latest created_at/response_file wins; across legs ONE winning leg is picked
# (PBSR > SBSR > ISR, else CTV) and status/reason/stage all come from that same leg.
EFF="WITH member_emission AS (\
 SELECT DISTINCT ON (e.arrival_id,m.sequence,m.e2e)\
 e.arrival_id,m.sequence,m.e2e,e.id AS emission_id\
 FROM crw_emission e JOIN crw_emission_member m ON m.emission_id=e.id\
 ORDER BY e.arrival_id,m.sequence,m.e2e,e.run_date DESC,e.batch_ordinal DESC),\
 isr_candidates AS (\
 SELECT r.emission_id,r.e2e,r.status,r.reason,r.created_at,r.response_file,true AS resolved\
 FROM isr_resp r WHERE r.emission_id IS NOT NULL\
 UNION ALL SELECT e.id,r.e2e,r.status,r.reason,r.created_at,r.response_file,false\
 FROM isr_resp r JOIN crw_emission e ON e.outbound_msg_id=r.orgnl_msg_id\
 WHERE r.emission_id IS NULL),\
 isr_pick AS (SELECT emission_id,e2e,status,reason,created_at FROM (\
 SELECT c.*,row_number() OVER (PARTITION BY emission_id,e2e\
 ORDER BY resolved DESC,created_at DESC,response_file DESC) AS rn FROM isr_candidates c) AS ranked WHERE rn=1),\
 sbsr_candidates AS (\
 SELECT r.emission_id,r.e2e,r.status,r.reason,r.created_at,r.response_file,true AS resolved\
 FROM sbsr_resp r WHERE r.emission_id IS NOT NULL\
 UNION ALL SELECT e.id,r.e2e,r.status,r.reason,r.created_at,r.response_file,false\
 FROM sbsr_resp r JOIN crw_emission e ON e.outbound_msg_id=r.orgnl_msg_id\
 WHERE r.emission_id IS NULL),\
 sbsr_pick AS (SELECT emission_id,e2e,status,reason,created_at FROM (\
 SELECT c.*,row_number() OVER (PARTITION BY emission_id,e2e\
 ORDER BY resolved DESC,created_at DESC,response_file DESC) AS rn FROM sbsr_candidates c) AS ranked WHERE rn=1),\
 pbsr_candidates AS (\
 SELECT r.emission_id,r.e2e,r.status,r.reason,r.created_at,r.response_file,true AS resolved\
 FROM pbsr_resp r WHERE r.emission_id IS NOT NULL\
 UNION ALL SELECT e.id,r.e2e,r.status,r.reason,r.created_at,r.response_file,false\
 FROM pbsr_resp r JOIN crw_emission e ON e.outbound_msg_id=r.orgnl_msg_id\
 WHERE r.emission_id IS NULL),\
 pbsr_pick AS (SELECT emission_id,e2e,status,reason,created_at FROM (\
 SELECT c.*,row_number() OVER (PARTITION BY emission_id,e2e\
 ORDER BY resolved DESC,created_at DESC,response_file DESC) AS rn FROM pbsr_candidates c) AS ranked WHERE rn=1),\
 eff AS (SELECT h.client_token AS client,t.arrival_id,t.sequence,t.e2e,me.emission_id,\
 t.debtor_account,t.amount,v.outcome AS ctv_outcome,\
 (substr(h.business_date,1,4)||'-'||substr(h.business_date,5,2)||'-'||substr(h.business_date,7,2))::DATE AS process_date,\
 COALESCE(pp.status,sp.status,ip.status,\
 CASE WHEN v.outcome='PASS' THEN 'CTV_PASS' ELSE v.outcome END) AS status,\
 CASE WHEN pp.status IS NOT NULL THEN pp.reason\
      WHEN sp.status IS NOT NULL THEN sp.reason\
      WHEN ip.status IS NOT NULL THEN ip.reason ELSE v.outcome END AS reason,\
 CASE WHEN pp.status IS NOT NULL THEN 'PBSR'\
      WHEN sp.status IS NOT NULL THEN 'SBSR'\
      WHEN ip.status IS NOT NULL THEN 'ISR' ELSE 'CTV' END AS stage\
 FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id\
 LEFT JOIN validation_log v ON v.arrival_id=t.arrival_id AND v.sequence=t.sequence\
 LEFT JOIN member_emission me ON me.arrival_id=t.arrival_id AND me.sequence=t.sequence AND me.e2e=t.e2e\
 LEFT JOIN isr_pick ip ON ip.emission_id=me.emission_id AND ip.e2e=t.e2e\
 LEFT JOIN sbsr_pick sp ON sp.emission_id=me.emission_id AND sp.e2e=t.e2e\
 LEFT JOIN pbsr_pick pp ON pp.emission_id=me.emission_id AND pp.e2e=t.e2e)"

check() {  # label, expected_sql(root, raw BASE), actual_sql(role, view), role, [cmd-array-name=SQL]
  local label=$1 esql=$2 asql=$3 role=$4 cmdvar=${5:-SQL}
  local -a cmd=( "${(@P)cmdvar}" )
  local e=$("${cmd[@]}" -e "$esql" | tail -1)
  local a=$("${cmd[@]}" --user=$role -e "$asql" | tail -1)
  if [[ -z "$e" || -z "$a" || ! "$e" =~ $num || ! "$a" =~ $num ]]; then
    echo "FAIL: $label non-numeric/empty (fail-closed) expected=[$e] actual=[$a]"; fail=1; return 0
  fi
  if [[ "$e" == "$a" ]]; then echo "PASS: $label ($e)"
  else echo "FAIL: $label expected=$e actual=$a"; fail=1; fi
}

for C in FNBCC01 FNBCC02 FNBRF01; do
  R=${C:l}
  check "$C total settled amount" \
    "$EFF SELECT COALESCE(sum(amount),0) FROM eff WHERE client='$C' AND status IN ('ACSC','ACCC')" \
    "SELECT COALESCE(sum(settled_amount),0) FROM rpt.v_tx_daily" "$R"
  check "$C tx count" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_tx_daily" "$R"
  check "$C ISR terminal non-success count" \
    "$EFF SELECT count(*) FROM eff WHERE client='$C' AND stage='ISR' AND status IN ('RJCT','CANC')" \
    "SELECT COALESCE(sum(fail_count),0) FROM rpt.v_reason_daily WHERE stage='ISR'" "$R"
  check "$C SBSR terminal non-success count" \
    "$EFF SELECT count(*) FROM eff WHERE client='$C' AND stage='SBSR' AND status IN ('RJCT','CANC')" \
    "SELECT COALESCE(sum(fail_count),0) FROM rpt.v_reason_daily WHERE stage='SBSR'" "$R"
  check "$C PBSR terminal non-success count" \
    "$EFF SELECT count(*) FROM eff WHERE client='$C' AND stage='PBSR' AND status IN ('RJCT','CANC')" \
    "SELECT COALESCE(sum(fail_count),0) FROM rpt.v_reason_daily WHERE stage='PBSR'" "$R"
  check "$C reason CTV fail count" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id JOIN validation_log v ON v.arrival_id=t.arrival_id AND v.sequence=t.sequence WHERE h.client_token='$C' AND v.outcome LIKE 'FAIL%'" \
    "SELECT COALESCE(sum(fail_count),0) FROM rpt.v_reason_daily WHERE stage='CTV'" "$R"
  check "$C debtor failed count" \
    "$EFF SELECT count(*) FROM eff WHERE client='$C' AND (status IN ('RJCT','CANC') OR ctv_outcome LIKE 'FAIL%')" \
    "SELECT COALESCE(sum(failed_count),0) FROM rpt.v_debtor_daily" "$R"
  check "$C debtor top failed amount" \
    "$EFF SELECT COALESCE(max(s),0) FROM (SELECT sum(amount) s FROM eff WHERE client='$C' AND (status IN ('RJCT','CANC') OR ctv_outcome LIKE 'FAIL%') GROUP BY debtor_account, process_date)" \
    "SELECT COALESCE(max(failed_amount),0) FROM rpt.v_debtor_daily" "$R"
  check "$C cure cured count (expect 0 -> panel empty is correct)" \
    "$EFF SELECT count(*) FROM eff f WHERE f.client='$C' AND (f.status IN ('RJCT','CANC') OR f.ctv_outcome LIKE 'FAIL%') AND EXISTS (SELECT 1 FROM eff s WHERE s.client=f.client AND s.debtor_account=f.debtor_account AND s.status IN ('ACSC','ACCC') AND s.process_date > f.process_date)" \
    "SELECT count(*) FROM rpt.v_cure WHERE days_to_cure IS NOT NULL" "$R"
  check "$C funnel SUBMITTED" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_funnel_daily WHERE stage='SUBMITTED'" "$R"
  check "$C funnel CTV_PASS" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id JOIN validation_log v ON v.arrival_id=t.arrival_id AND v.sequence=t.sequence WHERE h.client_token='$C' AND v.outcome='PASS'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_funnel_daily WHERE stage='CTV_PASS'" "$R"
  check "$C funnel EMITTED" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C' AND EXISTS(SELECT 1 FROM crw_emission e JOIN crw_emission_member m ON m.emission_id=e.id WHERE e.arrival_id=t.arrival_id AND m.sequence=t.sequence AND m.e2e=t.e2e)" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_funnel_daily WHERE stage='EMITTED'" "$R"
  check "$C funnel SETTLED" \
    "$EFF SELECT count(*) FROM eff WHERE client='$C' AND status IN ('ACSC','ACCC')" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_funnel_daily WHERE stage='SETTLED'" "$R"
  check "$C recon control sum" \
    "SELECT COALESCE(sum(cm.amount),0) FROM crw_emission_member cm JOIN crw_emission ce ON ce.id=cm.emission_id JOIN tx_header h ON h.arrival_id=ce.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(control_sum),0) FROM rpt.v_recon_daily" "$R"
  check "$C recon settled sum" \
    "$EFF SELECT COALESCE(sum(cm.amount) FILTER (WHERE p.status IN ('ACSC','ACCC')),0) FROM crw_emission_member cm JOIN crw_emission ce ON ce.id=cm.emission_id JOIN tx_header h ON h.arrival_id=ce.arrival_id LEFT JOIN pbsr_pick p ON p.emission_id=cm.emission_id AND p.e2e=cm.e2e WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(settled_sum),0) FROM rpt.v_recon_daily" "$R"
  check "$C recon variance" \
    "$EFF SELECT COALESCE(sum(cm.amount),0)-COALESCE(sum(cm.amount) FILTER (WHERE p.status IN ('ACSC','ACCC')),0) FROM crw_emission_member cm JOIN crw_emission ce ON ce.id=cm.emission_id JOIN tx_header h ON h.arrival_id=ce.arrival_id LEFT JOIN pbsr_pick p ON p.emission_id=cm.emission_id AND p.e2e=cm.e2e WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(variance),0) FROM rpt.v_recon_daily" "$R"
  check "$C p95 amount" \
    "SELECT percentile_cont(0.95::FLOAT8) WITHIN GROUP (ORDER BY t.amount::FLOAT8) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT percentile_cont(0.95::FLOAT8) WITHIN GROUP (ORDER BY amount::FLOAT8) FROM rpt.v_tx" "$R"
  check "$C bucket total tx" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C'" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_amount_buckets" "$R"
  check "$C bucket E_5K_PLUS count" \
    "SELECT count(*) FROM tx_entry t JOIN tx_header h ON h.arrival_id=t.arrival_id WHERE h.client_token='$C' AND t.amount >= 5000" \
    "SELECT COALESCE(sum(tx_count),0) FROM rpt.v_amount_buckets WHERE bucket='E_5K_PLUS'" "$R"
done

# agt_ops internal ops dashboard: entirely different base tables (stage_outcome + launch_intent).
# Raw as root vs the view as rpt_internal, both against the agt_ops DB (SQLO array).
check "ops business_count total" \
  "SELECT count(*) FILTER (WHERE so.outcome LIKE 'BUSINESS%') FROM stage_outcome so JOIN launch_intent li ON li.id=so.intent_id" \
  "SELECT COALESCE(sum(business_count),0) FROM rpt.v_ops_stage_health" rpt_internal SQLO
check "ops tech_failed_count total" \
  "SELECT count(*) FILTER (WHERE so.outcome='TECH_FAILED') FROM stage_outcome so JOIN launch_intent li ON li.id=so.intent_id" \
  "SELECT COALESCE(sum(tech_failed_count),0) FROM rpt.v_ops_stage_health" rpt_internal SQLO

# cross-client integrity: internal-role total == raw total over all clients (fail-closed on empty).
tot_i=$("${SQL[@]}" --user=rpt_internal -e "SELECT COALESCE(sum(total_amount),0) FROM rpt.v_tx_daily" | tail -1)
tot_r=$("${SQL[@]}" -e "SELECT COALESCE(sum(amount),0) FROM tx_entry" | tail -1)
if [[ -z "$tot_i" || -z "$tot_r" || ! "$tot_i" =~ $num || ! "$tot_r" =~ $num ]]; then
  echo "FAIL: internal integrity non-numeric/empty (fail-closed) internal=[$tot_i] raw=[$tot_r]"; fail=1
elif [[ "$tot_i" == "$tot_r" ]]; then echo "PASS: internal total == raw total ($tot_i)"
else echo "FAIL: internal $tot_i raw $tot_r"; fail=1; fi

exit $fail
