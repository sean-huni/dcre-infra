#!/usr/bin/env python3
"""DCRE OTLP alerting: the generator for alert rules and the contact point.

Alert rules and contact points are EMITTED BY THIS FILE and DELIVERED BY GRAFANA
FILE PROVISIONING. They are never clicked into existence and never posted through
``POST /api/v1/provisioning/...``. This file REPLACES ``scripts/grafana-alerts.sh``,
which drove the provisioning API and whose expressions carried three defects that
are silent on this fleet (see DEFECTS_IN_THE_REPLACED_SCRIPT below).

Two generated artifacts:

  k8s/base/06-obs-alerting.yml            a ConfigMap holding BOTH provisioning files
  k8s/overlays/alerting-slack/            an overlay that mounts the contact point

WHY THE CONTACT POINT IS NOT IN THE BASE, measured on kind-dcre-dev 2026-09-11.
It was, for six minutes, and those six minutes were a total Grafana outage. With
``$DCRE_SLACK_WEBHOOK_URL`` unset, Grafana expands it to EMPTY, stops treating the
integration as an incoming-webhook sender, falls through to the Slack chat API,
and refuses the receiver:

    failure to map file dcre-contact-points.yaml: failure parsing contact points:
    dcre-slack: failed to validate integration "dcre-slack" of type "slack":
    recipient must be specified when using the Slack chat API

A provisioning failure does NOT skip the offending file. It fails the whole
provisioning module, which every other module depends on, so the HTTP server never
starts: no dashboards, no datasources, no rule evaluation, readiness refused for as
long as it takes someone to read the log. Splitting the rules and the contact point
into two FILES did not contain it, which was this generator's first design and its
first wrong assumption.

So the default state of this repository provisions RULES ONLY, and cannot take
Grafana down whether the Secret exists or not. The contact point is a deliberate,
one-command opt-in taken once a REAL webhook is in the Secret:

    kubectl -n dcre create secret generic dcre-alerting-slack \
      --from-literal=webhook-url="$DCRE_SLACK_WEBHOOK_URL" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -k k8s/overlays/alerting-slack
    kubectl -n dcre rollout restart deploy/lgtm

A PLACEHOLDER URL is deliberately NOT offered as a default either, though it was
measured to validate and bring Grafana up in 5 seconds. A contact point that
validates and points nowhere reports as CONFIGURED while delivering nothing, which
is the exact failure shape the rest of this file exists to remove. Absent is honest;
placeholder is not.

The webhook URL is never in this repository. The provisioning file references the
environment variable ``$DCRE_SLACK_WEBHOOK_URL``, which the lgtm Deployment reads
from an OPTIONAL Kubernetes Secret.

Modes
-----
generate   rewrite the generated artifact (default)
--check    regenerate in memory and fail on any difference from the committed file,
           and fail when 04-lgtm.yml stops mounting a key this generator emits
--verify   run EVERY rule expression against the live Prometheus, refuse on a query
           error, and report which rules are ARMED (would fire now) and which are
           QUIET, so a rule that cannot fire is visible rather than assumed

Verification target: the in-cluster LGTM Grafana reached through a port-forward
(``kubectl -n dcre port-forward deploy/lgtm <port>:3000``). Pass ``--grafana`` to
point elsewhere. The ambient ``GRAFANA_URL`` is deliberately not read, for the same
reason obs-dashboards.py does not read it: it points the Grafana MCP at the compose
LGTM, which is a different Grafana, and inheriting it verifies the wrong instance.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = REPO_ROOT / "k8s" / "base" / "06-obs-alerting.yml"
OVERLAY_DIR = REPO_ROOT / "k8s" / "overlays" / "alerting-slack"
OVERLAY = OVERLAY_DIR / "kustomization.yml"
DEPLOYMENT = REPO_ROOT / "k8s" / "base" / "04-lgtm.yml"
KUSTOMIZATION = REPO_ROOT / "k8s" / "base" / "kustomization.yml"

CONFIGMAP_NAME = "dcre-obs-alerting"
NAMESPACE = "dcre"
PROVISIONING_DIR_IN_POD = "/otel-lgtm/grafana/conf/provisioning/alerting"
RULES_FILE = "dcre-alert-rules.yaml"
CONTACT_POINTS_FILE = "dcre-contact-points.yaml"

# The alerting folder is DELIBERATELY not the dashboards' "DCRE" folder. Two
# providers creating one folder title is a race with no upside, and a reader looking
# for rules should not have to read past four dashboards to find them.
ALERT_FOLDER = "DCRE Alerts"
RULE_GROUP = "dcre-fleet"
GROUP_INTERVAL = "30s"

CONTACT_POINT = "dcre-slack"
# The secret's own name is not a secret; its VALUE is, and the value is never here.
WEBHOOK_ENV = "DCRE_SLACK_WEBHOOK_URL"
SECRET_NAME = "dcre-alerting-slack"
SECRET_KEY = "webhook-url"

PROM_DS = "prometheus"

# --------------------------------------------------------------------------------------
# Measured facts. Every window below is a multiple of a step that was COUNTED on
# kind-dcre-dev on 2026-09-11, not a number copied from another fleet.
# --------------------------------------------------------------------------------------
#
#   count_over_time(target_info{job="agt"}[3m])          = 3    -> agt exports on a 60s step
#   count_over_time(up{job="otelcol-contrib"}[30s])      = 30   -> the collector's self-scrape
#                                                                  is pushed on a 1s step
#
# An absence window must be a MULTIPLE of the step and wider than one interval, or a
# single late export reads as a death. 3 intervals each, on both.
AGT_ABSENCE_WINDOW = "3m"
COLLECTOR_ABSENCE_WINDOW = "30s"

# The window over which an ephemeral stage pod's one exported sample still counts.
# Long enough to survive a scheduling gap between Kubernetes Job executions, short
# enough that the alert resolves on its own once the failures stop.
BATCH_WINDOW = "15m"

FOR_DURATION = "15s"

DEFECTS_IN_THE_REPLACED_SCRIPT = """
scripts/grafana-alerts.sh, which this generator replaces, was never loaded into
kind-dcre-dev (the cluster held 0 rules and 0 contact points on 2026-09-11). Four
defects, all of which would have been silent had it run:

  1. absent(agt_file_arrivals_total) twice over. absent() is an INSTANT vector and
     reads Prometheus's five minute lookback. A scrape target that disappears gets a
     staleness marker; this fleet PUSHES over OTLP and a push exporter that stops
     gets none, so the series still resolves for five minutes after the process died
     and a rule whose `for` is 10m can never fire before the evidence of death has
     itself expired. Every absence expression here is absent_over_time.
  2. increase(agt_file_arrivals_total{status="DAG_FAILED"}[15m]). That metric is a
     GAUGE polled from the database despite its _total suffix (obs-dashboards.py
     GAUGE_NOTE), so increase() over it is meaningless.
  3. sum(dcre_sla_pending_amber). MEASURED: count(dcre_sla_pending_amber) returns 0
     series and the metric name does not exist in this Prometheus at all. The rule
     could never fire in either direction.
  4. "Contact point: Grafana default", i.e. none. A rule with no contact point is a
     colour on a screen nobody is looking at.
""".strip()

GENERATED_BANNER = [
    "# GENERATED FILE. DO NOT EDIT.",
    "#",
    "# Emitted by scripts/obs-alerting.py. Edit that generator and re-run it:",
    "#     python3 scripts/obs-alerting.py",
    "# `python3 scripts/obs-alerting.py --check` fails when this file has drifted from",
    "# the generator, and `--verify` runs every rule expression against the live",
    "# Prometheus before this file is allowed to be published.",
    "#",
    "# Delivery is Grafana FILE PROVISIONING, not the HTTP API. The proof that it came",
    "# from a file is that every rule reads back from",
    "# /api/v1/provisioning/alert-rules with provenance `file`, which the UI renders as",
    "# read-only.",
    "#",
    "# NO SECRET IS IN THIS FILE. The Slack webhook is referenced as the environment",
    f"# variable ${WEBHOOK_ENV}, which 04-lgtm.yml reads from the OPTIONAL",
    f"# Secret {SECRET_NAME}. See README, section Alerting.",
]


# --------------------------------------------------------------------------------------
# A minimal, always-quoted YAML emitter
# --------------------------------------------------------------------------------------
#
# PyYAML is not installed on this machine and obs-dashboards.py deliberately carries no
# third-party dependency, so this generator carries none either. Every scalar string is
# emitted DOUBLE QUOTED with backslash and quote escaped, which is unambiguous YAML for
# any content, so no expression, description or PromQL operator can change the meaning
# of the document by looking like YAML syntax. Booleans, integers and null go bare.

def yaml_scalar(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    s = str(v)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def to_yaml(obj, indent: int = 0) -> list[str]:
    pad = "  " * indent
    out: list[str] = []
    if isinstance(obj, dict):
        if not obj:
            return [pad + "{}"]
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                out.append(f"{pad}{k}:")
                out.extend(to_yaml(v, indent + 1))
            elif isinstance(v, (dict, list)):
                out.append(f"{pad}{k}: {'{}' if isinstance(v, dict) else '[]'}")
            else:
                out.append(f"{pad}{k}: {yaml_scalar(v)}")
        return out
    if isinstance(obj, list):
        if not obj:
            return [pad + "[]"]
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                block = to_yaml(item, indent + 1)
                first = block[0].lstrip()
                out.append(f"{pad}- {first}")
                out.extend(block[1:])
            else:
                out.append(f"{pad}- {yaml_scalar(item)}")
        return out
    return [pad + yaml_scalar(obj)]


# --------------------------------------------------------------------------------------
# The rules
# --------------------------------------------------------------------------------------
#
# Each entry states, in its own description, the NUMBER that triggered it and what the
# expression can and cannot see. `runbook` is a command a responder pastes, because an
# alert that says something is wrong without saying what to run is a dead end.

RULES = [
    {
        "uid": "dcre-orchestrator-absent",
        "title": "DCRE orchestrator absent",
        "severity": "critical",
        "expr": f'absent_over_time(target_info{{job="agt"}}[{AGT_ABSENCE_WINDOW}])',
        "summary": "The DCRE orchestrator {{ $labels.job }} has stopped exporting telemetry.",
        "description": (
            "No target_info sample from job={{ $labels.job }} for "
            f"{AGT_ABSENCE_WINDOW}; the absence indicator reads {{{{ $values.B }}}} "
            "(1 means absent). The orchestrator is a single-replica Deployment and the "
            "fleet stops without it: nothing leases, nothing launches, no stage Job is "
            "created. "
            "WHY absent_over_time AND NOT absent: this fleet PUSHES over OTLP. A scrape "
            "target that disappears gets a staleness marker and absent() sees it; a push "
            "exporter that stops gets none, so absent() keeps reading the last sample for "
            "Prometheus's five minute lookback and the alert never fires. "
            f"WHY a {AGT_ABSENCE_WINDOW} window: agt exports on a 60s step, MEASURED as "
            f"count_over_time(target_info{{job=\"agt\"}}[{AGT_ABSENCE_WINDOW}]) = 3 on "
            "2026-09-11. The window is three intervals, so one late export cannot be read "
            "as a death. Detection latency is therefore up to "
            f"{AGT_ABSENCE_WINDOW} plus {FOR_DURATION}."
        ),
        "runbook": (
            "kubectl --context kind-dcre-dev -n dcre get pods -l app=dcre-agt ; "
            "kubectl --context kind-dcre-dev -n dcre logs deploy/dcre-agt --tail=200 ; "
            "kubectl --context kind-dcre-dev -n dcre describe deploy/dcre-agt"
        ),
    },
    {
        "uid": "dcre-collector-absent",
        "title": "DCRE OTLP collector absent",
        "severity": "critical",
        "expr": f'absent_over_time(up{{job="otelcol-contrib"}}[{COLLECTOR_ABSENCE_WINDOW}])',
        "summary": "The OTLP collector {{ $labels.job }} has stopped reporting; the fleet is "
                   "flying blind.",
        "description": (
            "No up sample from job={{ $labels.job }} for "
            f"{COLLECTOR_ABSENCE_WINDOW}; the absence indicator reads {{{{ $values.B }}}}. "
            "Every metric, log and trace in this fleet arrives through this collector, so "
            "its silence means every OTHER panel and rule is reading history rather than "
            "the present. "
            "WHAT up IS HERE, which is not what it usually is: the bundle's Prometheus has "
            "NO scrape_configs at all. up{job=\"otelcol-contrib\"} is the collector's own "
            "prometheus/collector receiver scraping 127.0.0.1:8888 every 1s and PUSHING the "
            "result through the OTLP pipeline. It is therefore a pushed series like every "
            "other, which is why this is absent_over_time and not up == 0: a dead collector "
            "cannot report itself down, so up == 0 would never be true. "
            f"WHY a {COLLECTOR_ABSENCE_WINDOW} window: MEASURED as "
            f"count_over_time(up{{job=\"otelcol-contrib\"}}[{COLLECTOR_ABSENCE_WINDOW}]) = 30 "
            "on 2026-09-11, a 1s step, so the window is 30 intervals. "
            "WHAT THIS CANNOT SEE: the collector, Prometheus, Alertmanager and Grafana are "
            "one pod. If the POD dies, the evaluator dies with it and nothing here fires. "
            "That watchdog has to live outside the pod and does not yet exist."
        ),
        "runbook": (
            "kubectl --context kind-dcre-dev -n dcre get pod -l app.kubernetes.io/name=lgtm ; "
            "kubectl --context kind-dcre-dev -n dcre logs deploy/lgtm --tail=200 | grep -i otelcol ; "
            "kubectl --context kind-dcre-dev -n dcre exec deploy/lgtm -- curl -s localhost:13133/ready"
        ),
    },
    {
        "uid": "dcre-database-unreachable",
        "title": "DCRE fleet cannot obtain a database connection",
        "severity": "critical",
        "expr": f"sum by (job) (last_over_time(hikaricp_connections_timeout_total[{BATCH_WINDOW}]))",
        "summary": "{{ $labels.job }} timed out acquiring a CockroachDB connection.",
        "description": (
            "{{ $labels.job }} reported {{ $values.B }} Hikari connection-acquisition "
            f"timeouts inside the last {BATCH_WINDOW}. A pool that cannot hand out a "
            "connection is the fleet-side signature of CockroachDB being unreachable, "
            "unhealthy, or out of connection capacity. "
            "READ THE LIMIT OF THIS RULE BEFORE TRUSTING IT. CockroachDB publishes NOTHING "
            "into this Prometheus. Measured 2026-09-11: crdb-0 serves 18406 lines on "
            "http://localhost:8080/_status/vars and NOTHING scrapes them, the bundle's "
            "prometheus.yaml has no scrape_configs, and label_values(job) is exactly "
            "agt, dcre-*, otelcol-contrib. So there is no such thing as a direct "
            "\"CockroachDB absent\" rule on this cluster today and this is the closest "
            "honest proxy: it detects a database outage only once something TRIES to use "
            "the database and fails, and the things that try are ephemeral Kubernetes Jobs. "
            "An outage in the gap between two Job executions is invisible to it. "
            "The fix is to give CockroachDB a scrape path into this Prometheus; until then "
            "this rule is a smoke detector in one room of the house."
        ),
        "runbook": (
            "kubectl --context kind-dcre-dev -n dcre get pod crdb-0 ; "
            "kubectl --context kind-dcre-dev -n dcre exec crdb-0 -- "
            "./cockroach sql --insecure --execute 'SELECT 1' ; "
            "kubectl --context kind-dcre-dev -n dcre logs crdb-0 --tail=200"
        ),
    },
    {
        "uid": "dcre-stage-batch-job-failed",
        "title": "DCRE stage Spring Batch job executions ended FAILED",
        "severity": "critical",
        "expr": ('sum by (job) (last_over_time('
                 'spring_batch_job_milliseconds_count{spring_batch_job_status="FAILED"}'
                 f"[{BATCH_WINDOW}]))"),
        "summary": "{{ $labels.job }} has Spring Batch job executions in status FAILED.",
        "description": (
            "{{ $labels.job }} reported {{ $values.B }} Spring Batch job executions with "
            f"spring_batch_job_status=FAILED inside the last {BATCH_WINDOW}. Measured "
            "2026-09-11: dcre-mrg 29, dcre-crg 15, dcre-cix 1, dcre-cpx 1, dcre-csx 1. "
            "WHY THE CUMULATIVE COUNTER AND NOT increase(): a stage service is a Spring "
            "Batch job inside a Kubernetes Job. It exports ONCE and the pod exits, so the "
            "next execution is a new pod, a new instance label and therefore a NEW SERIES "
            "carrying exactly one sample. rate() and increase() both need two samples on "
            "ONE series inside the window, so both are EMPTY here by construction, forever. "
            "Red-proofed on the live datasource on 2026-09-11: "
            "sum by (job) (increase(spring_batch_job_milliseconds_count"
            "{spring_batch_job_status=\"FAILED\"}[5m])) returned 0 series while the "
            "expression above returned 5. "
            "WHY NOT THE X - X offset FORM either: a cumulative difference assumes the "
            "series at T and at T minus the offset are the SAME series. Here they are "
            "different pods, so the subtraction would compare unrelated counters. "
            "last_over_time over an explicit window sums each ephemeral pod's own count "
            "and states its universe instead of inheriting Prometheus's lookback flag."
        ),
        "runbook": (
            "kubectl --context kind-dcre-dev -n dcre get jobs --sort-by=.metadata.creationTimestamp "
            "| tail -20 ; "
            "kubectl --context kind-dcre-dev -n dcre logs job/<name> --tail=200 ; "
            "kubectl --context kind-dcre-dev -n dcre get pods --field-selector=status.phase=Failed"
        ),
    },
    {
        "uid": "dcre-sla-breach-red",
        "title": "DCRE SLA breached waiting for a Fintegrate response",
        "severity": "critical",
        "expr": "max by (job, client, flow) (dcre_sla_pending_red)",
        "summary": "{{ $labels.client }} {{ $labels.flow }} has transactions past the red SLA "
                   "({{ $labels.job }}).",
        "description": (
            "{{ $values.B }} transactions for client {{ $labels.client }} on flow "
            "{{ $labels.flow }} have waited past the red SLA threshold (default 24h) for a "
            "Fintegrate response. Measured 2026-09-11: FNBRF01 COL = 51. "
            "AGGREGATED WITH max(), NOT sum(): this is a GAUGE polled from the database by "
            "every agt pod, so every pod reports the same number and overlapping pod "
            "generations would multiply the fleet's own restarts into the figure. Same "
            "convention as the Overview board. "
            "The amber counterpart that the superseded HTTP-API alert script alerted on does "
            "not exist: "
            "count(dcre_sla_pending_amber) returns 0 series and the metric name is absent "
            "from this Prometheus entirely."
        ),
        "runbook": (
            "Open the DCRE Fleet Overview board, SLA pending (red) panel, at this time range ; "
            "kubectl --context kind-dcre-dev -n dcre logs deploy/dcre-agt --tail=200 | grep -i sla ; "
            "escalate to Fintegrate per the response-leg runbook"
        ),
    },
]


# --------------------------------------------------------------------------------------
# Rendering: rules
# --------------------------------------------------------------------------------------

def rule_yaml_obj(r: dict) -> dict:
    """One Grafana alert rule: query A, reduce B, threshold C, condition C.

    noDataState is OK on EVERY rule here, and that is a decision rather than a default.
    An absence expression returns a value only while the thing is absent, so a healthy
    fleet makes it return NOTHING; a threshold rule over a counter returns nothing when
    no failure has occurred. With noDataState Alerting or NoData, every one of these
    rules would page continuously while the fleet was perfectly well.

    execErrState is Alerting, which is the opposite decision for the opposite reason: a
    datasource that cannot answer is a fault, and a rule that goes quiet when its query
    breaks is the silent failure this whole file exists to remove.
    """
    return {
        "uid": r["uid"],
        "title": r["title"],
        "condition": "C",
        "for": FOR_DURATION,
        "noDataState": "OK",
        "execErrState": "Alerting",
        "isPaused": False,
        "labels": {
            "severity": r["severity"],
            "system": "dcre",
        },
        "annotations": {
            "summary": r["summary"],
            "description": r["description"],
            "runbook": r["runbook"],
        },
        "data": [
            {
                "refId": "A",
                "relativeTimeRange": {"from": 900, "to": 0},
                "datasourceUid": PROM_DS,
                "model": {
                    "refId": "A",
                    "datasource": {"type": "prometheus", "uid": PROM_DS},
                    "expr": r["expr"],
                    "instant": True,
                    "range": False,
                    "editorMode": "code",
                    "legendFormat": "__auto",
                    "intervalMs": 1000,
                    "maxDataPoints": 43200,
                },
            },
            {
                "refId": "B",
                "relativeTimeRange": {"from": 0, "to": 0},
                "datasourceUid": "__expr__",
                "model": {
                    "refId": "B",
                    "datasource": {"type": "__expr__", "uid": "__expr__"},
                    "type": "reduce",
                    "expression": "A",
                    "reducer": "last",
                    "settings": {"mode": ""},
                },
            },
            {
                "refId": "C",
                "relativeTimeRange": {"from": 0, "to": 0},
                "datasourceUid": "__expr__",
                "model": {
                    "refId": "C",
                    "datasource": {"type": "__expr__", "uid": "__expr__"},
                    "type": "threshold",
                    "expression": "B",
                    "conditions": [{
                        "type": "query",
                        "evaluator": {"type": "gt", "params": [0]},
                        "operator": {"type": "and"},
                        "query": {"params": ["B"]},
                        "reducer": {"type": "last", "params": []},
                    }],
                },
            },
        ],
    }


def rules_file() -> str:
    doc = {
        "apiVersion": 1,
        "groups": [{
            "orgId": 1,
            "name": RULE_GROUP,
            "folder": ALERT_FOLDER,
            "interval": GROUP_INTERVAL,
            "rules": [rule_yaml_obj(r) for r in RULES],
        }],
    }
    header = [
        "# GENERATED by scripts/obs-alerting.py. DO NOT EDIT.",
        "#",
        "# Every rule below keeps its OWN labelset. There is deliberately no rule that ORs",
        "# several absence terms together under one static job label: N absence terms each",
        "# return their own job, and stamping one job over all of them makes Prometheus",
        "# refuse the whole rule with \"vector contains metrics with the same labelset after",
        "# applying alert labels\" the moment TWO services are absent, which is precisely the",
        "# case such a rule exists for.",
        "#",
        "# Every summary names {{ $labels.job }} and every description carries the number",
        "# that triggered it and a runbook line to paste.",
    ]
    return "\n".join(header + to_yaml(doc)) + "\n"


# --------------------------------------------------------------------------------------
# Rendering: the contact point and the notification policy
# --------------------------------------------------------------------------------------

SLACK_TEXT = (
    "{{ range .Alerts }}"
    "*{{ .Labels.alertname }}*  severity={{ .Labels.severity }}  job={{ .Labels.job }}\n"
    "{{ .Annotations.summary }}\n"
    "{{ .Annotations.description }}\n"
    "RUNBOOK: {{ .Annotations.runbook }}\n"
    "{{ end }}"
)


def contact_points_file() -> str:
    doc = {
        "apiVersion": 1,
        "contactPoints": [{
            "orgId": 1,
            "name": CONTACT_POINT,
            "receivers": [{
                "uid": "dcre-slack-webhook",
                "type": "slack",
                # NO SECRET HERE. Grafana expands $VAR in provisioning files from the
                # process environment; 04-lgtm.yml supplies this one from an OPTIONAL
                # Kubernetes Secret, so a clone with no secret still starts, still loads
                # this contact point, and simply delivers nowhere.
                "settings": {
                    "url": f"${WEBHOOK_ENV}",
                    "title": "{{ .Status | toUpper }}: {{ .CommonLabels.alertname }}",
                    "text": SLACK_TEXT,
                },
                "disableResolveMessage": False,
            }],
        }],
        "policies": [{
            "orgId": 1,
            "receiver": CONTACT_POINT,
            "group_by": ["alertname", "job"],
            "group_wait": "10s",
            # group_interval gates the RESOLVED message too, not only repeats. At the 5m
            # default, a service restored in 90 seconds is still reported down for four
            # more minutes, and the all-clear is the message a responder acts on by
            # standing down. repeat_interval stays long so a live alert does not train
            # the channel to ignore it.
            "group_interval": "1m",
            "repeat_interval": "4h",
        }],
    }
    header = [
        "# GENERATED by scripts/obs-alerting.py. DO NOT EDIT.",
        "#",
        "# THE WEBHOOK URL IS NOT IN THIS FILE AND NEVER WILL BE. The value below is the",
        f"# literal string ${WEBHOOK_ENV}, which Grafana expands from its own process",
        f"# environment at provisioning time. 04-lgtm.yml supplies it from the OPTIONAL",
        f"# Secret {SECRET_NAME}, key {SECRET_KEY}, which is NOT in this repository and",
        "# NOT in kustomize base, so `kubectl apply -k` can never overwrite a populated one.",
        "#",
        "# This file is SEPARATE from the rules file on purpose: Grafana validates an",
        "# alerting provisioning file as a unit, and a contact point that fails validation",
        "# must not be able to take the rules down with it.",
    ]
    return "\n".join(header + to_yaml(doc)) + "\n"


# The ConfigMap carries BOTH files so the contact point's exact content is generated,
# committed and reviewable in a diff. Only BASE_MOUNTED is mounted by k8s/base; the
# contact point is mounted by the overlay, which is why an unpopulated Secret is
# harmless in the default state rather than a Grafana outage.
BASE_MOUNTED = (RULES_FILE,)
OVERLAY_MOUNTED = (CONTACT_POINTS_FILE,)


def provisioning_files() -> dict[str, str]:
    return {RULES_FILE: rules_file(), CONTACT_POINTS_FILE: contact_points_file()}


def overlay_kustomization() -> str:
    """The one-command opt-in that mounts the contact point.

    A strategic-merge patch, so the volume and volumeMount lists MERGE on `name`
    rather than replacing the base's own dashboard and rule mounts. Applying this
    overlay without a populated Secret reproduces the outage described at the top of
    this file, which is why the README makes creating the Secret step one.
    """
    return f"""# GENERATED by scripts/obs-alerting.py. DO NOT EDIT.
#
# OPT-IN OVERLAY: mounts the Slack contact point into Grafana's alerting provisioning
# directory. The base deliberately does NOT mount it, because an unpopulated webhook
# makes Grafana refuse to start ENTIRELY (measured on kind-dcre-dev 2026-09-11: a six
# minute total outage, dashboards and datasources included, from one receiver that
# could not validate).
#
# ORDER MATTERS AND IS NOT OPTIONAL. Create the Secret FIRST:
#
#   kubectl -n {NAMESPACE} create secret generic {SECRET_NAME} \\
#     --from-literal={SECRET_KEY}="${WEBHOOK_ENV}" \\
#     --dry-run=client -o yaml | kubectl apply -f -
#   kubectl apply -k k8s/overlays/alerting-slack
#   kubectl -n {NAMESPACE} rollout restart deploy/lgtm
#
# Grafana reads provisioning files ONCE at startup, so the restart is what actually
# delivers the change, and it is the step that is easy to forget.
#
# BACKING IT OUT TAKES THREE STEPS, NOT ONE, and the third is the one nobody expects.
# Grafana PERSISTS a file-provisioned alerting resource in its own database. Removing
# the file does NOT remove the contact point: measured 2026-09-11, after the mount was
# taken away and the pod restarted, GET /api/v1/provisioning/contact-points still
# returned dcre-slack with provenance "file", pointing at a Secret that no longer
# existed. Un-mounting un-provisions nothing.
#
#   kubectl apply -k k8s/base
#   kubectl -n {NAMESPACE} rollout restart deploy/lgtm
#   curl -u admin:admin -H 'X-Disable-Provenance: true' -X DELETE \\
#     http://localhost:3001/api/v1/provisioning/policies
#   curl -u admin:admin -H 'X-Disable-Provenance: true' -X DELETE \\
#     http://localhost:3001/api/v1/provisioning/contact-points/dcre-slack-webhook
#
# The X-Disable-Provenance header is required: without it Grafana refuses to delete a
# resource it believes a file still owns.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - target:
      kind: Deployment
      name: lgtm
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: lgtm
        namespace: {NAMESPACE}
      spec:
        template:
          spec:
            containers:
              - name: lgtm
                volumeMounts:
                  - name: dcre-alerting
                    mountPath: {PROVISIONING_DIR_IN_POD}/{CONTACT_POINTS_FILE}
                    subPath: {CONTACT_POINTS_FILE}
                    readOnly: true
"""


def render_configmap() -> str:
    files = provisioning_files()
    lines = list(GENERATED_BANNER)
    lines += [
        "---",
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: {CONFIGMAP_NAME}",
        f"  namespace: {NAMESPACE}",
        "  labels:",
        "    app.kubernetes.io/name: lgtm",
        "    app.kubernetes.io/component: alerting",
        "data:",
    ]
    for name in sorted(files):
        lines.append(f"  {name}: |")
        for line in files[name].rstrip("\n").split("\n"):
            lines.append(f"    {line}" if line else "")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------------------
# The manifests as CHECKED CONSUMERS
# --------------------------------------------------------------------------------------

def check_manifests() -> list[str]:
    """04-lgtm.yml names every provisioning file BY NAME, and so does this generator.

    That is two homes for one fact and its failure is silent in both directions: add a
    third provisioning file here and forget the manifest, and the file simply never
    mounts, the rules simply never load, and nothing anywhere goes red. Remove one here
    and leave it in the manifest, and the pod refuses to start on a missing key. This
    turns the manifest into a checked consumer rather than a second source.
    """
    findings: list[str] = []
    if not DEPLOYMENT.exists():
        return [f"{DEPLOYMENT} does not exist"]
    dep = DEPLOYMENT.read_text()
    keys = sorted(provisioning_files())

    if f"name: {CONFIGMAP_NAME}" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not reference ConfigMap {CONFIGMAP_NAME}")

    # BOTH keys must be PROJECTED by the volume, so the overlay's subPath has something
    # to find; only the base-mounted one may be MOUNTED here.
    for key in keys:
        if f"- key: {key}" not in dep:
            findings.append(f"{DEPLOYMENT.name} does not project ConfigMap key {key}")

    for key in BASE_MOUNTED:
        # subPath, not a directory mount: mounting the directory would shadow the
        # bundle's own alerting/sample.yaml and any future file Grafana ships there.
        if f"{PROVISIONING_DIR_IN_POD}/{key}" not in dep:
            findings.append(f"{DEPLOYMENT.name} does not mount {key} at "
                            f"{PROVISIONING_DIR_IN_POD}/{key}")
        if f"subPath: {key}" not in dep:
            findings.append(f"{DEPLOYMENT.name} does not mount {key} with subPath")

    # THE LOAD-BEARING ONE. The base must NOT mount the contact point. With the webhook
    # variable unset Grafana refuses the receiver and then refuses to start at all, so a
    # base that mounts it turns a missing Secret into a total monitoring outage. Measured
    # 2026-09-11; this assertion is the only thing standing between that and a re-run.
    for key in OVERLAY_MOUNTED:
        if f"{PROVISIONING_DIR_IN_POD}/{key}" in dep:
            findings.append(f"{DEPLOYMENT.name} MOUNTS {key} in the BASE. That makes an "
                            f"unpopulated {SECRET_NAME} Secret a total Grafana outage, not a "
                            f"quiet contact point. It belongs in k8s/overlays/alerting-slack")

    projected = [ln.strip()[len("- key: "):] for ln in dep.splitlines()
                 if ln.strip().startswith("- key: ")]
    stale = sorted(set(k for k in projected if k.startswith("dcre-alert")
                       or k.startswith("dcre-contact")) - set(keys))
    if stale:
        findings.append(f"{DEPLOYMENT.name} projects alerting keys this generator does not "
                        f"emit: {', '.join(stale)}")

    # The webhook reaches Grafana as an environment variable or the contact point is
    # provisioned with an unexpanded reference. The FULL declaration line, not the bare
    # name: red-proofing this gate on 2026-09-11 renamed the variable to
    # DCRE_SLACK_WEBHOOK_URL_TYPO and the check PASSED, because a substring test is
    # satisfied by any name that merely contains the right one.
    if f"- name: {WEBHOOK_ENV}\n" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not declare `- name: {WEBHOOK_ENV}` in the "
                        f"lgtm container env")
    if f"name: {SECRET_NAME}" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not reference Secret {SECRET_NAME}")
    # The secretKeyRef's OWN indented line. A bare substring test for "optional: true"
    # passed while the manifest said false, because the phrase also appears in the
    # COMMENT above explaining why it must be true. A check satisfied by a comment in the
    # file under test is not a check.
    if "\n                  optional: true\n" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not mark the {SECRET_NAME} secretKeyRef "
                        f"optional, so a clone without the Secret cannot start")

    if KUSTOMIZATION.exists() and ARTIFACT.name not in KUSTOMIZATION.read_text():
        findings.append(f"{KUSTOMIZATION.name} does not list {ARTIFACT.name} under resources")

    # The overlay is the ONLY sanctioned way to turn the contact point on, so it is
    # generated and drift-checked exactly like the ConfigMap.
    if not OVERLAY.exists():
        findings.append(f"{OVERLAY} does not exist; run the generator")
    elif OVERLAY.read_text() != overlay_kustomization():
        findings.append(f"{OVERLAY.relative_to(REPO_ROOT)} differs from the generator")

    # A secret that reached the repository is the finding this check exists for.
    #
    # The needle is ASSEMBLED rather than written out, so this file does not itself
    # contain the literal it hunts for. Written whole, the check failed on its own source
    # on its first run, and a self-matching guard is one someone eventually deletes.
    needle = "hooks." + "slack.com"
    for path in (ARTIFACT, DEPLOYMENT, KUSTOMIZATION, OVERLAY, Path(__file__)):
        if path.exists() and needle in path.read_text():
            findings.append(f"SECRET LEAK: {path.name} contains a literal Slack webhook host")
    return findings


# --------------------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------------------

def http_json(url: str, timeout: int = 60, user: str = "admin", password: str = "admin"):
    req = urllib.request.Request(url)
    import base64
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r), None
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace")
        return None, f"HTTP {e.code}: {body}"
    except Exception as e:  # noqa: BLE001 - the message is the finding
        return None, f"{type(e).__name__}: {e}"


def verify(grafana: str) -> int:
    """Run every rule expression against the live Prometheus.

    An ERROR refuses publication. An expression that returns nothing is reported as
    QUIET rather than passed over in silence, because a rule that cannot fire and a
    rule with nothing to report look identical from here, and the difference is the
    whole question. ARMED means the expression returns a value above the threshold
    right now, which is the only cheap proof that a rule's query path works end to end.
    """
    d, err = http_json(f"{grafana}/api/health", timeout=15)
    if err or not (d or {}).get("version"):
        print(f"REFUSED: {grafana}/api/health did not answer ({err or d})", file=sys.stderr)
        return 2
    print(f"verifying against {grafana} (Grafana {d['version']})")

    errors, armed, quiet = [], [], []
    for r in RULES:
        url = (f"{grafana}/api/datasources/proxy/uid/{PROM_DS}/api/v1/query?"
               + urllib.parse.urlencode({"query": r["expr"]}))
        res, err = http_json(url)
        if err:
            verdict, detail = "ERROR", err
        elif res.get("status") != "success":
            verdict, detail = "ERROR", f"{res.get('errorType')}: {res.get('error')}"
        else:
            series = res["data"]["result"]
            over = [s for s in series if float(s["value"][1]) > 0]
            detail = f"{len(series)} series, {len(over)} above threshold"
            verdict = "ARMED" if over else "QUIET"
        {"ERROR": errors, "ARMED": armed, "QUIET": quiet}[verdict].append((r, detail))
        print(f"  {verdict:5s} {r['uid']:32s} {detail}")
        if verdict == "ERROR":
            print(f"        query: {r['expr']}")

    print(f"\n{'-' * 78}")
    print(f"rules: {len(RULES)}   ARMED: {len(armed)}   QUIET: {len(quiet)}   "
          f"ERROR: {len(errors)}")
    if quiet:
        print("\nQUIET rules (the expression runs and reports nothing above threshold; each "
              "one is a healthy fleet OR a rule that cannot fire, and the description says "
              "which):")
        for r, _ in quiet:
            print(f"  {r['uid']}")
    if errors:
        print("\nREFUSING TO PUBLISH: a rule expression returned an error.", file=sys.stderr)
        for r, detail in errors:
            print(f"  {r['uid']}: {detail}\n    {r['expr']}", file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="fail when the committed artifact differs from the generator")
    ap.add_argument("--verify", action="store_true",
                    help="run every rule expression against the live Prometheus")
    ap.add_argument("--grafana", default="http://localhost:3001",
                    help="Grafana base URL for --verify (default: http://localhost:3001)")
    ap.add_argument("--defects", action="store_true",
                    help="print what was wrong with the script this generator replaces")
    args = ap.parse_args()

    if args.defects:
        print(DEFECTS_IN_THE_REPLACED_SCRIPT)
        return 0
    if args.verify:
        return verify(args.grafana.rstrip("/"))

    rendered = render_configmap()
    if args.check:
        if not ARTIFACT.exists():
            print(f"DRIFT: {ARTIFACT} does not exist", file=sys.stderr)
            return 1
        committed = ARTIFACT.read_text()
        if committed != rendered:
            print(f"DRIFT: {ARTIFACT} differs from scripts/obs-alerting.py.", file=sys.stderr)
            print("Re-run `python3 scripts/obs-alerting.py` and commit the result.",
                  file=sys.stderr)
            import difflib
            diff = difflib.unified_diff(committed.splitlines(), rendered.splitlines(),
                                        "committed", "generated", lineterm="", n=1)
            for line in list(diff)[:60]:
                print(line, file=sys.stderr)
            return 1
        findings = check_manifests()
        if findings:
            print("DRIFT: the manifests do not agree with the generator.", file=sys.stderr)
            for f in findings:
                print(f"  {f}", file=sys.stderr)
            return 1
        print(f"OK: {ARTIFACT.relative_to(REPO_ROOT)} matches the generator "
              f"({len(RULES)} rules, 1 contact point, 1 notification policy). "
              f"{DEPLOYMENT.name} mounts {', '.join(BASE_MOUNTED)} and does NOT mount "
              f"{', '.join(OVERLAY_MOUNTED)}, so a missing {SECRET_NAME} Secret cannot "
              f"stop Grafana. {OVERLAY.relative_to(REPO_ROOT)} matches the generator")
        return 0

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(rendered)
    OVERLAY_DIR.mkdir(parents=True, exist_ok=True)
    overlay = overlay_kustomization()
    OVERLAY.write_text(overlay)
    print(f"wrote {ARTIFACT.relative_to(REPO_ROOT)} "
          f"({len(RULES)} rules, {len(provisioning_files())} provisioning files, "
          f"{len(rendered)} bytes)")
    print(f"wrote {OVERLAY.relative_to(REPO_ROOT)} "
          f"(opt-in mount for {', '.join(OVERLAY_MOUNTED)}, {len(overlay)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
