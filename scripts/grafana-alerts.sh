#!/bin/zsh
# DCRE Grafana alert rules (SCRUM-61 + SCRUM-62 in-band half).
#
# Provisions five alert rules into the IN-CLUSTER LGTM Grafana via the HTTP
# provisioning API, deterministically (same convention as grafana-dashboards.sh:
# the Grafana MCP is the optional alternative authoring path, dashboard/alert
# JSON is never hand-maintained in the repo).
#
#   dcre-sla-amber        sum(dcre_sla_pending_amber) > 0 for 5m   warning
#   dcre-sla-red          sum(dcre_sla_pending_red)   > 0 for 1m   critical
#   dcre-dag-failed       increase(agt_file_arrivals_total{status="DAG_FAILED"}[15m]) > 0   critical
#   dcre-tech-failed      increase(agt_stage_outcomes_total{outcome="TECH_FAILED"}[15m]) > 0  warning
#   dcre-telemetry-silent absent(agt_file_arrivals_total) for 10m  critical
#
# Design notes:
# * SLA gauges are registered lazily per client by AGT SlaMonitor, so an empty
#   series is the HEALTHY state: both SLA rules use noDataState=OK and only the
#   telemetry-silent rule owns absence detection (via the always-on AGT ledger
#   gauge, republished every 10s while AGT lives).
# * telemetry-silent covers the lgtm-up.sh documented silent-drop path (OTLP
#   exporters fail open) AND an AGT death. It cannot cover the LGTM pod itself
#   dying (the evaluator dies with it) - that out-of-band watchdog is the open
#   residual on SCRUM-62.
# * Contact point: Grafana default (email is not wired in kind; the red gauge
#   panel + firing state in the UI is the dev-cluster signal).
#
# Idempotent: fixed rule UIDs; PUT if the rule exists, POST otherwise.
# Target: in-cluster Grafana via scripts/lgtm-forward.sh (svc/lgtm 3000 -> :3001).
set -e
set -o pipefail
G="${DCRE_GRAFANA_URL:-http://localhost:3001}"
AUTH="admin:admin"
HDR=(-H "Content-Type: application/json" -H "X-Disable-Provenance: true")

# Folder (idempotent: 409/412 on re-run is fine, then read back).
curl -s -o /dev/null -u "$AUTH" "${HDR[@]}" -X POST "$G/api/folders" \
  -d '{"uid":"dcre-alerts","title":"DCRE Alerts"}' || true
curl -sf -u "$AUTH" "$G/api/folders/dcre-alerts" >/dev/null

rule_json() {  # uid title promql for_duration severity nodata summary
  python3 - "$@" <<'PY'
import json, sys
uid, title, expr, dur, sev, nodata, summary = sys.argv[1:8]
print(json.dumps({
    "uid": uid, "orgID": 1, "folderUID": "dcre-alerts", "ruleGroup": "dcre",
    "title": title, "condition": "C", "for": dur,
    "noDataState": nodata, "execErrState": "Alerting",
    "labels": {"severity": sev, "system": "dcre"},
    "annotations": {"summary": summary},
    "data": [
        {"refId": "A", "relativeTimeRange": {"from": 600, "to": 0},
         "datasourceUid": "prometheus",
         "model": {"refId": "A", "expr": expr, "instant": True, "range": False,
                    "intervalMs": 1000, "maxDataPoints": 43200}},
        {"refId": "C", "relativeTimeRange": {"from": 0, "to": 0},
         "datasourceUid": "__expr__",
         "model": {"refId": "C", "type": "threshold", "expression": "A",
                    "conditions": [{"evaluator": {"type": "gt", "params": [0]},
                                     "operator": {"type": "and"},
                                     "query": {"params": ["C"]},
                                     "reducer": {"type": "last", "params": []},
                                     "type": "query"}]}}
    ]}))
PY
}

upsert() {  # uid json
  if curl -sf -u "$AUTH" "$G/api/v1/provisioning/alert-rules/$1" >/dev/null 2>&1; then
    curl -sf -u "$AUTH" "${HDR[@]}" -X PUT "$G/api/v1/provisioning/alert-rules/$1" -d "$2" >/dev/null
    echo "updated $1"
  else
    curl -sf -u "$AUTH" "${HDR[@]}" -X POST "$G/api/v1/provisioning/alert-rules" -d "$2" >/dev/null
    echo "created $1"
  fi
}

upsert dcre-sla-amber "$(rule_json dcre-sla-amber \
  'DCRE SLA amber: Fintegrate response pending > amber threshold' \
  'sum(dcre_sla_pending_amber)' '5m' warning OK \
  'At least one transaction has waited past the amber SLA threshold (default 20h) for a Fintegrate response.')"

upsert dcre-sla-red "$(rule_json dcre-sla-red \
  'DCRE SLA red: Fintegrate response SLA breached' \
  'sum(dcre_sla_pending_red)' '1m' critical OK \
  'SLA breach (default 24h) waiting for a Fintegrate response. Escalate to Fintegrate per runbook.')"

upsert dcre-dag-failed "$(rule_json dcre-dag-failed \
  'DCRE arrival DAG failed' \
  'sum(increase(agt_file_arrivals_total{status="DAG_FAILED"}[15m]))' '0s' critical OK \
  'An inbound arrival DAG reached DAG_FAILED in the last 15 minutes.')"

upsert dcre-tech-failed "$(rule_json dcre-tech-failed \
  'DCRE stage TECH_FAILED outcomes' \
  'sum(increase(agt_stage_outcomes_total{outcome="TECH_FAILED"}[15m]))' '0s' warning OK \
  'Stage executions ended TECH_FAILED in the last 15 minutes (fugu F16 alert half).')"

upsert dcre-telemetry-silent "$(rule_json dcre-telemetry-silent \
  'DCRE telemetry silent (AGT gauges absent)' \
  'absent(agt_file_arrivals_total)' '10m' critical Alerting \
  'The always-on AGT ledger gauge vanished: AGT is down or the OTLP path/LGTM collector is silently dropping telemetry (lgtm-up.sh failure mode).')"

echo "--- read-back verification ---"
curl -sf -u "$AUTH" "$G/api/v1/provisioning/alert-rules" \
  | python3 -c 'import json,sys; rules=[r for r in json.load(sys.stdin) if r.get("folderUID")=="dcre-alerts"]; [print(r["uid"], "|", r["title"], "| for", r["for"], "|", r["labels"].get("severity")) for r in sorted(rules,key=lambda r:r["uid"])]; assert len(rules)==5, f"expected 5 rules, found {len(rules)}"; print("VERIFIED: 5/5 rules present")'
