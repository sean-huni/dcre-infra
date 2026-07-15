#!/bin/zsh
# DCRE Grafana dashboard packs (spec M8 client-stats, Task 13).
#
# Posts two dashboard packs into the IN-CLUSTER LGTM Grafana via the HTTP API,
# deterministically (the Grafana MCP is the optional alternative authoring path):
#   * dcre-client-stats  (uid dcre-client-stats)  -> EVERY org, identical JSON
#     (session-identity portability: the same client pack renders per-org because
#      each org has its own dcre-rpt datasource scoped to that client's data).
#   * dcre-internal-stats (uid dcre-internal-stats) -> FNB Internal ONLY, rows 1-5
#     on the org's dcre-rpt datasource, rows 6-7 on its dcre-ops datasource.
#
# Idempotent by design: POST /api/dashboards/db with overwrite:true + a FIXED uid
# updates in place, so re-runs (Task 16) never create duplicates.
#
# Target the in-cluster Grafana on host :3001 (scripts/lgtm-forward.sh forwards
# svc/lgtm 3000 -> host 3001). We deliberately do NOT read the ambient GRAFANA_URL:
# that points the Grafana MCP at the *compose* LGTM on :3000 (a different Grafana).
# Override this script's target with DCRE_GRAFANA_URL if ever needed - same
# convention as scripts/grafana-provision.sh (Task 12).
#
# CockroachDB note: the reporting datasource (dcre-rpt/dcre-ops) is CockroachDB on
# the postgres wire protocol. CRDB is stricter than PostgreSQL about implicit
# numeric coercion, so six ratio/percentile queries carry minimal, semantics-
# preserving ::FLOAT casts vs the brief's PostgreSQL SQL (marked CRDB-CAST below):
#   client  3  success_rate       - FLOAT/INT   -> cast divisor ::FLOAT
#   client  7  amount p50/p95      - percentile_cont over decimal -> ::FLOAT operands
#   client 13  value/count weight  - FLOAT/decimal -> cast divisors ::FLOAT
#   client 15  median days-to-cure - percentile_cont over int -> ::FLOAT operands
#   internal 3 fail rate by client - FLOAT/INT   -> cast divisor ::FLOAT
#   internal 6 TECH_FAILED ratio   - FLOAT/INT   -> cast divisor ::FLOAT
# Without these casts CRDB rejects the query (SQLSTATE 22023 / 42883) and the panel
# renders an error - contradicting the brief's own expectation that stat panels show
# full data. Every cast leaves the numeric result identical to PostgreSQL.
set -e
set -o pipefail
G="${DCRE_GRAFANA_URL:-http://localhost:3001}"
AUTH="admin:admin"

org_id() {  # org_name
  curl -sf -u "$AUTH" "$G/api/orgs/name/${1// /%20}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

ds_uid() {  # org_id, ds_name
  curl -sf -u "$AUTH" -H "X-Grafana-Org-Id: $1" "$G/api/datasources/name/$2" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["uid"])'
}

# Emit the full POST body {"overwrite":true,"dashboard":{...}} for a dashboard.
# Each row is "dsuid|type|title|format|sql" so a single dashboard can mix
# datasources (internal pack: dcre-rpt rows + dcre-ops rows). Panels tile 2-wide.
build_dashboard() {  # uid, title, rows...
  python3 - "$@" <<'PY'
import json, sys
uid, title, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
panels = []
for i, row in enumerate(rows):
    ds, ptype, ptitle, fmt, sql = row.split("|", 4)
    panels.append({
        "id": i + 1, "title": ptitle, "type": ptype,
        "gridPos": {"h": 8, "w": 12, "x": (i % 2) * 12, "y": (i // 2) * 8},
        "datasource": {"type": "postgres", "uid": ds},
        "targets": [{"refId": "A", "format": fmt, "rawSql": sql}],
    })
print(json.dumps({"overwrite": True, "dashboard": {
    "uid": uid, "title": title, "timezone": "utc", "schemaVersion": 39,
    "refresh": "1m", "time": {"from": "now-30d", "to": "now"},
    "panels": panels}}))
PY
}

post_dash() {  # org_name, uid, title, rows...
  local org=$1 uid=$2 title=$3; shift 3
  local oid; oid=$(org_id "$org")
  local resp; resp=$(build_dashboard "$uid" "$title" "$@" \
    | curl -sf -u "$AUTH" -H "X-Grafana-Org-Id: $oid" -H 'Content-Type: application/json' \
        -X POST "$G/api/dashboards/db" --data-binary @-)
  local ver; ver=$(print -r -- "$resp" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
  print -r -- "posted $uid v$ver -> $org (org_id=$oid)"
}

# --- Client pack: 15 panels, all on the org's dcre-rpt datasource. ------------
# Rows are "type|title|format|sql" (dsuid prepended per org at post time).
CLIENT_PANELS=(
  'stat|Total collected (since inception)|table|SELECT COALESCE(sum(settled_amount),0) FROM rpt.v_tx_daily'
  'timeseries|Tx per day + settled|time_series|SELECT process_date AS "time", total_amount, settled_amount FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|Success rate % per day|time_series|SELECT process_date AS "time", settled_count::FLOAT/NULLIF(tx_count,0)::FLOAT*100 AS success_rate FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|Running total collected|time_series|SELECT process_date AS "time", sum(settled_amount) OVER (ORDER BY process_date) AS running_total FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|7-cycle moving average|time_series|SELECT process_date AS "time", avg(total_amount) OVER (ORDER BY process_date ROWS 6 PRECEDING) AS ma7 FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|Day-over-day delta|time_series|SELECT process_date AS "time", total_amount - lag(total_amount) OVER (ORDER BY process_date) AS dod FROM rpt.v_tx_daily ORDER BY 1'
  'stat|Amount p50 / p95 (range)|table|SELECT percentile_cont(0.5::FLOAT) WITHIN GROUP (ORDER BY amount::FLOAT) AS p50, percentile_cont(0.95::FLOAT) WITHIN GROUP (ORDER BY amount::FLOAT) AS p95 FROM rpt.v_tx'
  'barchart|Fails by reason|table|SELECT reason, sum(fail_count) AS fails FROM rpt.v_reason_daily GROUP BY 1 ORDER BY 2 DESC'
  'timeseries|Early (CTV) vs late (PBSR) fails|time_series|SELECT process_date AS "time", stage, sum(fail_count) AS fails FROM rpt.v_reason_daily GROUP BY 1,2 ORDER BY 1'
  'table|Top 10 debtors by failed amount|table|SELECT debtor_account, sum(failed_amount) AS failed, sum(failed_count) AS times FROM rpt.v_debtor_daily GROUP BY 1 ORDER BY 2 DESC LIMIT 10'
  'table|Funnel (drop-off)|table|SELECT stage, sum(tx_count) AS tx, sum(total_amount) AS amount FROM rpt.v_funnel_daily GROUP BY stage, stage_order ORDER BY stage_order'
  'table|Reconciliation variance (R-24)|table|SELECT process_date, file_name, control_sum, settled_sum, variance FROM rpt.v_recon_daily ORDER BY 1 DESC LIMIT 20'
  'timeseries|Value-weighted vs count fail rate|time_series|SELECT process_date AS "time", (rejected_late_amount+rejected_early_amount)::FLOAT/NULLIF(total_amount,0)::FLOAT*100 AS value_weighted, (rejected_late_count+rejected_early_count)::FLOAT/NULLIF(tx_count,0)::FLOAT*100 AS count_weighted FROM rpt.v_tx_daily ORDER BY 1'
  'barchart|Amount histogram|table|SELECT bucket, sum(tx_count) AS tx FROM rpt.v_amount_buckets GROUP BY 1 ORDER BY 1'
  'stat|Cure: median days-to-cure|table|SELECT percentile_cont(0.5::FLOAT) WITHIN GROUP (ORDER BY days_to_cure::FLOAT) FROM rpt.v_cure WHERE days_to_cure IS NOT NULL'
)

# --- Internal pack: rows 1-5 on dcre-rpt, rows 6-7 on dcre-ops. ---------------
INTERNAL_RPT_PANELS=(
  'timeseries|Collected per client per day|time_series|SELECT process_date AS "time", client, settled_amount FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|Client vs peer average|time_series|SELECT process_date AS "time", client, total_amount, avg(total_amount) OVER (PARTITION BY process_date) AS peer_avg FROM rpt.v_tx_daily ORDER BY 1'
  'timeseries|Fail rate by client|time_series|SELECT process_date AS "time", client, (rejected_late_count+rejected_early_count)::FLOAT/NULLIF(tx_count,0)::FLOAT*100 AS fail_rate FROM rpt.v_tx_daily ORDER BY 1'
  'table|Debtor concentration (top decile share)|table|SELECT client, sum(total_amount) FILTER (WHERE decile = 1)/NULLIF(sum(total_amount),0)*100 AS top_decile_pct FROM (SELECT client, total_amount, ntile(10) OVER (PARTITION BY client ORDER BY total_amount DESC) AS decile FROM rpt.v_debtor_daily) GROUP BY client'
  'timeseries|Reason mix over time|time_series|SELECT process_date AS "time", reason, sum(fail_count) AS fails FROM rpt.v_reason_daily GROUP BY 1,2 ORDER BY 1'
)
INTERNAL_OPS_PANELS=(
  'timeseries|Stage health: TECH_FAILED ratio|time_series|SELECT process_date AS "time", stage, tech_failed_count::FLOAT/NULLIF(total,0)::FLOAT*100 AS tech_failed_pct FROM rpt.v_ops_stage_health ORDER BY 1'
  'timeseries|Arrival-to-outcome SLA p95 seconds|time_series|SELECT observed_at AS "time", stage, extract(epoch FROM arrival_to_outcome) AS seconds FROM rpt.v_ops_sla ORDER BY 1'
)

# --- Post the client pack into every org. -------------------------------------
for org in FNBCC01 FNBCC02 FNBRF01 "FNB Internal"; do
  oid=$(org_id "$org")
  rpt=$(ds_uid "$oid" dcre-rpt)
  rows=()
  for p in "${CLIENT_PANELS[@]}"; do rows+=("$rpt|$p"); done
  post_dash "$org" dcre-client-stats "DCRE Client Stats" "${rows[@]}"
done

# --- Post the internal pack into FNB Internal only. ---------------------------
oid=$(org_id "FNB Internal")
rpt=$(ds_uid "$oid" dcre-rpt)
ops=$(ds_uid "$oid" dcre-ops)
irows=()
for p in "${INTERNAL_RPT_PANELS[@]}"; do irows+=("$rpt|$p"); done
for p in "${INTERNAL_OPS_PANELS[@]}"; do irows+=("$ops|$p"); done
post_dash "FNB Internal" dcre-internal-stats "DCRE Internal Stats" "${irows[@]}"

echo "OK"
