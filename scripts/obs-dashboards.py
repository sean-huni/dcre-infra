#!/usr/bin/env python3
"""DCRE OTLP observability dashboards: the generator.

Dashboards are EMITTED BY THIS FILE and DELIVERED BY GRAFANA FILE PROVISIONING.
They are never clicked into existence, never hand-maintained as JSON, and never
posted through ``POST /api/dashboards/db``. The superseded HTTP-API path still
exists for the client-stats packs in ``scripts/grafana-dashboards.sh``; this file
shares nothing with it and does not extend it.

The single generated artifact is ``k8s/base/05-obs-dashboards.yml``, a ConfigMap
holding one Grafana dashboard provider and four dashboard JSONs. The lgtm
Deployment mounts the provider into Grafana's provisioning directory and the
dashboards into ``/etc/dcre/dashboards``. Nothing in this repository holds a
second copy of a dashboard, so there is no drift pair to keep in step; ``--check``
re-runs the generator and fails when the committed artifact has been hand-edited.

Modes
-----
generate   rewrite the generated artifact (default)
--check    regenerate in memory and fail on any difference from the committed file
--verify   run EVERY panel target against the live datasources, refuse on a query
           error, and list every target that returned empty

Verification target: the in-cluster LGTM Grafana reached through a port-forward
(``kubectl -n dcre port-forward svc/lgtm <port>:3000``). Pass ``--grafana`` to
point elsewhere. The ambient ``GRAFANA_URL`` is deliberately not read: it points
the Grafana MCP at the compose LGTM, which is a different Grafana, and inheriting
it silently verifies the wrong instance. Same convention as grafana-provision.sh.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = REPO_ROOT / "k8s" / "base" / "05-obs-dashboards.yml"
DEPLOYMENT = REPO_ROOT / "k8s" / "base" / "04-lgtm.yml"
KUSTOMIZATION = REPO_ROOT / "k8s" / "base" / "kustomization.yml"

CONFIGMAP_NAME = "dcre-obs-dashboards"
NAMESPACE = "dcre"
DASHBOARD_DIR_IN_POD = "/etc/dcre/dashboards"
GRAFANA_FOLDER = "DCRE"

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}

# Every service this fleet publishes under. The orchestrator is `agt`; the 28 stage
# services publish as `dcre-<leaf>`, a name validated by StageIdentity in
# platform-batch (`Pattern.compile("dcre-[a-z]+")`). One constant, interpolated
# everywhere, so a change to the naming is a one-line edit rather than a hunt.
FLEET_JOBS = 'agt|dcre-.*'
STAGE_JOBS = 'dcre-.*'

# The orchestrator exports on a 60s step, measured 2026-09-11:
# count_over_time(agt_lease_held[10m]) = 10. An absence or liveness window must be a
# multiple of that step and wider than one interval, so absence is not declared on a
# single late export. _global/observability.md section 2.
LIVENESS_WINDOW = "3m"

GENERATED_BANNER = [
    "# GENERATED FILE. DO NOT EDIT.",
    "#",
    "# Emitted by scripts/obs-dashboards.py. Edit that generator and re-run it:",
    "#     python3 scripts/obs-dashboards.py",
    "# `python3 scripts/obs-dashboards.py --check` fails when this file has drifted",
    "# from the generator, and `--verify` runs every panel query against the live",
    "# datasources before this file is allowed to be published.",
    "#",
    "# Delivery is Grafana FILE PROVISIONING, not the HTTP API. The proof that it came",
    "# from a file is two-part: every dashboard reports meta.provisioned true, and the",
    "# Grafana log holds zero POSTs to /api/dashboards/db.",
]


# --------------------------------------------------------------------------------------
# Panel helpers
# --------------------------------------------------------------------------------------

def prom(expr: str, legend: str = "", instant: bool = False, fmt: str = "time_series") -> dict:
    return {
        "datasource": PROM,
        "expr": expr,
        "legendFormat": legend or "__auto",
        "instant": instant,
        "range": not instant,
        "format": fmt,
        "refId": "A",
    }


def loki(expr: str, legend: str = "", instant: bool = False, query_type: str = "range") -> dict:
    return {
        "datasource": LOKI,
        "expr": expr,
        "legendFormat": legend or "__auto",
        "queryType": query_type,
        "instant": instant,
        "range": not instant,
        "refId": "A",
    }


def tempo(query: str) -> dict:
    return {
        "datasource": TEMPO,
        "query": query,
        "queryType": "traceql",
        "limit": 20,
        "tableType": "traces",
        "refId": "A",
    }


def panel(ptype: str, title: str, description: str, targets: list[dict], **opts) -> dict:
    p = {
        "type": ptype,
        "title": title,
        "description": description,
        "datasource": targets[0]["datasource"],
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "unit": opts.pop("unit", "short"),
                "decimals": opts.pop("decimals", None),
                "color": {"mode": opts.pop("color_mode", "palette-classic")},
                "custom": opts.pop("custom", {}),
                "mappings": opts.pop("mappings", []),
                "thresholds": opts.pop(
                    "thresholds",
                    {"mode": "absolute", "steps": [{"color": "text", "value": None}]},
                ),
            },
            "overrides": opts.pop("overrides", []),
        },
        "options": opts.pop("options", {}),
        "w": opts.pop("w", 12),
        "h": opts.pop("h", 8),
    }
    if opts:
        raise ValueError(f"unconsumed panel options for {title!r}: {sorted(opts)}")
    return p


def stat(title, description, targets, **opts):
    opts.setdefault(
        "options",
        {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value",
            "graphMode": "area",
            "textMode": "auto",
            "justifyMode": "auto",
        },
    )
    opts.setdefault("w", 6)
    opts.setdefault("h", 5)
    opts.setdefault("color_mode", "thresholds")
    return panel("stat", title, description, targets, **opts)


def timeseries(title, description, targets, **opts):
    opts.setdefault(
        "custom",
        {
            "drawStyle": "line",
            "lineWidth": 2,
            "fillOpacity": 12,
            "showPoints": "auto",
            "spanNulls": False,
        },
    )
    opts.setdefault("options", {"legend": {"displayMode": "list", "placement": "bottom",
                                           "showLegend": True},
                                "tooltip": {"mode": "multi", "sort": "desc"}})
    return panel("timeseries", title, description, targets, **opts)


def table(title, description, targets, **opts):
    opts.setdefault("options", {"showHeader": True, "cellHeight": "sm",
                                "footer": {"show": False, "reducer": ["sum"]}})
    opts.setdefault("custom", {"align": "auto", "filterable": True})
    return panel("table", title, description, targets, **opts)


def bargauge(title, description, targets, **opts):
    opts.setdefault("options", {"displayMode": "gradient", "orientation": "horizontal",
                                "reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                                  "values": False},
                                "showUnfilled": True})
    opts.setdefault("color_mode", "thresholds")
    return panel("bargauge", title, description, targets, **opts)


def piechart(title, description, targets, **opts):
    opts.setdefault("options", {"displayLabels": ["name", "value"],
                                "legend": {"displayMode": "list", "placement": "right",
                                           "showLegend": True},
                                "pieType": "donut",
                                "reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                                  "values": False}})
    return panel("piechart", title, description, targets, **opts)


def logs(title, description, targets, **opts):
    opts.setdefault("options", {"showTime": True, "wrapLogMessage": True,
                                "sortOrder": "Descending", "enableLogDetails": True,
                                "dedupStrategy": "none", "prettifyLogMessage": False})
    opts.setdefault("w", 24)
    opts.setdefault("h", 11)
    return panel("logs", title, description, targets, **opts)


UP_DOWN_MAPPING = [
    {"type": "value", "options": {"1": {"text": "LIVE", "color": "green", "index": 0}}},
    {"type": "special", "options": {"match": "null", "result": {"text": "SILENT",
                                                                "color": "red", "index": 1}}},
]

def zero_when_live(expr: str) -> str:
    """Render an orchestrator gauge whose HEALTHY value is zero as 0 rather than No data.

    These gauges are built by polling the database, so a value with zero rows produces NO
    SERIES rather than a zero. On a stat panel that reads "No data", which is the same
    thing the panel shows when the query is broken and when the service is dead: three
    different conditions rendered identically, and the one that means everything is fine
    is the most common.

    `or vector(0)` would fix the display and break the meaning, because it reports a
    confident 0 for a dead orchestrator too. The fallback arm is therefore gated on the
    orchestrator actually having exported inside the liveness window, so the panel reads
    0 when the gauge has no rows AND the service is alive, and falls back to No data when
    the service is silent. max() around the fallback drops target_info's labels so the
    stat renders a bare number.

    Measured 2026-09-11: the live arm returns 14 for status=ABANDONED, the fallback arm
    returns 0 for a status with no rows, and the same expression without the fallback
    returns 0 series.
    """
    return (f'{expr} or on() '
            f'(0 * max(present_over_time(target_info{{job="agt"}}[{LIVENESS_WINDOW}])))')


ZERO_NOTE = (
    "Reads 0 rather than No data when the orchestrator is alive and the gauge has no rows, "
    "and falls back to No data only when the orchestrator itself has stopped exporting. A "
    "bare gauge would render all three of healthy-zero, dead-service and broken-query "
    "identically."
)

GREEN_ABOVE = {"mode": "absolute", "steps": [{"color": "red", "value": None},
                                             {"color": "green", "value": 1}]}
RED_ABOVE = {"mode": "absolute", "steps": [{"color": "green", "value": None},
                                           {"color": "red", "value": 1}]}


# --------------------------------------------------------------------------------------
# The four dashboards
# --------------------------------------------------------------------------------------

GAUGE_NOTE = (
    "SOURCE: an orchestrator GAUGE, polled from the database, despite the _total suffix. "
    "Two properties of that follow the panel: a value with zero rows produces NO SERIES "
    "rather than a zero, and a value that leaves the table keeps its last reading for ever. "
    "Aggregated with max(), not sum(): every agt pod polls the same database and reports the "
    "same number, and up to 3 pod generations were measured reporting at once on 2026-09-11 "
    "(10 of 32 sampled minutes), so sum() would multiply the fleet's own restarts into the "
    "figure. job=agt carries no instance label, so host_name is the only thing separating "
    "pod generations."
)

COUNTER_NOTE = (
    "SOURCE: a genuine monotonic COUNTER, incremented on the event itself, so rate() over it "
    "is meaningful and a value that stops occurring decays to zero instead of freezing. "
    "Summed across pods because each process owns its own counter."
)

STAGE_EMPTY_NOTE = (
    "EMPTY UNTIL THE FLEET RUNS. The 28 stage services publish as job=dcre-<leaf> and none of "
    "them was reporting when this board was generated, because a migration defect was crashing "
    "them at startup. Empty here means the stage fleet is not up, not that the panel is broken; "
    "the orchestrator panels on this same board are the control that proves the board works."
)

SPRING_BATCH_NOTE = (
    "METRIC NAME DERIVED, NOT YET OBSERVED. Spring Batch 6.0.4 creates the observations "
    "spring.batch.job and spring.batch.step with keys spring.batch.job.name / .status and "
    "spring.batch.step.name / .type / .job.name / .status, read from the bytecode of "
    "AbstractJob and AbstractStep in spring-batch-core-6.0.4.jar. Micrometer's OTLP registry "
    "uses MILLISECONDS as its base time unit, which is why every Micrometer timer already in "
    "this Prometheus renders as <name>_milliseconds_* (jvm_gc_pause_milliseconds_bucket, "
    "http_server_connections_duration_milliseconds). The name matcher accepts both the "
    "millisecond and the second rendering so a unit change upstream cannot silently empty this "
    "panel. " + STAGE_EMPTY_NOTE
)


# A stage service is a Spring Batch job in a Kubernetes Job: it exports ONCE and the pod dies,
# and the next execution is a new pod, so it is a new `instance` and therefore a NEW SERIES.
# Measured 2026-09-11 on kind-dcre-dev: 25 series, every one of them carrying exactly ONE sample
# inside a five-minute window. rate() and increase() both need two samples in the window ON ONE
# SERIES, so both return EMPTY here, forever, and four panels rendered "No data" against a fleet
# that was running fine. The cumulative counter is what carries the information: summing it over
# the ephemeral series counts executions, and sum/count gives the mean duration that
# histogram_quantile(rate(...)) cannot.
BATCH_EPHEMERAL_NOTE = (
    "Each execution is its own pod and therefore its own series, exporting once before it exits, "
    "so rate() and increase() are empty by construction here and this panel reads the cumulative "
    "counter instead. Measured: 25 series, one sample each per five-minute window."
)

def overview_dashboard() -> dict:
    return {
        "uid": "dcre-fleet-overview",
        "title": "DCRE Fleet Overview",
        "description": "Landing page for the DCRE fleet's OTLP telemetry: who is reporting, "
                       "what the arrivals and stage outcomes are doing, and where the SLA "
                       "pressure is. Generated by scripts/obs-dashboards.py and delivered by "
                       "Grafana file provisioning.",
        "tags": ["dcre", "generated"],
        "panels": [
            stat(
                "Services reporting telemetry",
                "How many distinct jobs published an OTLP resource in the dashboard's time "
                "range. Counted over JOBS and not over series: Prometheus derives job from "
                "service.name, and counting series would report the number of resource "
                "attribute combinations instead of the number of services. Reads 1 while only "
                "the orchestrator is up and 29 once all 28 stage services report.",
                [prom(f'count(count by (job) (max_over_time(target_info{{job=~"{FLEET_JOBS}"}}[$__range])))',
                      "services", instant=True)],
                thresholds=GREEN_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Orchestrator telemetry",
                "LIVE when the orchestrator exported at least one resource sample inside the "
                f"last {LIVENESS_WINDOW}. Built on present_over_time and NOT on absent(): these "
                "are PUSHED metrics, and a push exporter that stops gets no staleness marker, so "
                "absent() keeps answering healthy for the whole five-minute lookback after the "
                "process has died. SILENT is rendered from the no-data mapping, so an empty "
                f"result is a verdict rather than a blank. The {LIVENESS_WINDOW} window is three "
                "times the measured 60s export step.",
                [prom(f'present_over_time(target_info{{job="agt"}}[{LIVENESS_WINDOW}])',
                      "agt", instant=True)],
                mappings=UP_DOWN_MAPPING, thresholds=GREEN_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Orchestrator lease held",
                "1 when an orchestrator replica holds the scheduling lease. Zero or absent means "
                "nothing is launching stage jobs. " + GAUGE_NOTE,
                [prom("max(agt_lease_held)", "lease", instant=True)],
                thresholds=GREEN_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Oldest in-flight DAG",
                "Age of the oldest arrival still in DAG_RUNNING. A number that only grows is a "
                "stuck DAG. " + ZERO_NOTE + " " + GAUGE_NOTE,
                [prom(zero_when_live("max(agt_dag_running_oldest_age_seconds)"), "oldest", instant=True)],
                unit="s",
            ),
            stat(
                "Business success share",
                "Share of stage outcomes in the BUSINESS success classes. Success at stage level "
                "is outcome IN (BUSINESS_ACCEPTED, BUSINESS_PARTIAL): there is no SUCCESS "
                "constant, so a panel that looked for one would read zero for ever. "
                "BUSINESS_PARTIAL carries no series while nothing has been partially accepted, "
                "which is the zero-rows-means-no-series property, and the regex sum tolerates "
                "that. The divisor is clamped so an empty fleet renders 0 rather than NaN. "
                + GAUGE_NOTE,
                [prom('sum(max by (outcome) (agt_stage_outcomes_total{outcome=~"BUSINESS_ACCEPTED|BUSINESS_PARTIAL"}))'
                      ' / clamp_min(sum(max by (outcome) (agt_stage_outcomes_total)), 1)',
                      "business success", instant=True)],
                unit="percentunit", decimals=2,
            ),
            stat(
                "Stage services reporting",
                "The 28 stage services only. Separate from the fleet count beside it so an "
                "orchestrator that is up on its own cannot make the board look populated. "
                + STAGE_EMPTY_NOTE,
                [prom(f'count(count by (job) (max_over_time(target_info{{job=~"{STAGE_JOBS}"}}[$__range])))',
                      "stage services", instant=True)],
                thresholds=GREEN_ABOVE, color_mode="thresholds",
            ),
            table(
                "Jobs reporting telemetry",
                "Every job that published a resource in the time range, with the number of "
                "resource series behind it. More than one row per job means more than one pod "
                "generation reported inside the window, which is normal across a restart and is "
                "the reason the gauge panels aggregate with max().",
                [prom(f'count by (job) (max_over_time(target_info{{job=~"{FLEET_JOBS}"}}[$__range]))',
                      "{{job}}", instant=True, fmt="table")],
                w=12, h=6,
            ),
            piechart(
                "File arrivals by status",
                "Arrival-level state of every file the orchestrator has seen. Arrival success is "
                "ArrivalStatus.DAG_COMPLETE; DAG_RUNNING is in flight and DAG_FAILED is the "
                "terminal failure. " + GAUGE_NOTE,
                [prom("max by (status) (agt_file_arrivals_total)", "{{status}}", instant=True)],
                w=12, h=8,
            ),
            bargauge(
                "Stage outcomes by class",
                "Every stage outcome class the orchestrator has recorded. BUSINESS_ACCEPTED and "
                "BUSINESS_PARTIAL are the success classes; TECH_FAILED, TECH_EXHAUSTED and "
                "TECH_CONFIG_FAILED are infrastructure failures; BUSINESS_FILE_REJECTED is a "
                "file the business rules turned away. " + GAUGE_NOTE,
                [prom("max by (outcome) (agt_stage_outcomes_total)", "{{outcome}}", instant=True)],
                w=12, h=8,
            ),
            bargauge(
                "Launch intents by status",
                "Write-ahead launch intents. INTENDED is written before the job is launched, "
                "LAUNCHED after the orchestrator has seen it start, ABANDONED when the intent was "
                "never converted. A growing INTENDED count with a flat LAUNCHED count is the "
                "orchestrator failing to launch. " + GAUGE_NOTE,
                [prom("max by (status) (agt_launch_intents_total)", "{{status}}", instant=True)],
                w=12, h=6,
            ),
            timeseries(
                "Stage outcome events per second",
                "Rate of stage outcomes as they happen. " + COUNTER_NOTE + " The neighbouring "
                "bar gauge shows the same classes as CURRENT TOTALS from the gauge; this panel is "
                "the only one of the two that can show a rate, because rate() over a gauge whose "
                "value can fall is meaningless.",
                [prom("sum by (outcome) (rate(agt_stage_outcome_events_total[$__rate_interval]))",
                      "{{outcome}}")],
                w=12, h=8,
            ),
            timeseries(
                "Arrival transitions per second",
                "Rate of arrival state transitions. " + COUNTER_NOTE + " A flat zero across every "
                "status while files are present means the orchestrator has stopped advancing "
                "arrivals.",
                [prom("sum by (status) (rate(agt_arrival_transitions_total[$__rate_interval]))",
                      "{{status}}")],
                w=12, h=8,
            ),
            table(
                "SLA pending, red",
                "Client and flow combinations breaching the red SLA threshold, with the count "
                "pending. " + GAUGE_NOTE + " An empty table is the healthy state.",
                [prom("max by (client, flow) (dcre_sla_pending_red)", "{{client}} {{flow}}",
                      instant=True, fmt="table")],
                thresholds=RED_ABOVE, color_mode="thresholds", w=12, h=7,
            ),
            table(
                "SLA pending, amber",
                "Client and flow combinations breaching the amber SLA threshold. EXPECTED EMPTY "
                "at generation time: dcre_sla_pending_amber did not exist in Prometheus at all on "
                "2026-09-11, while dcre_sla_pending_red did, because these SLA gauges are "
                "registered lazily per client and flow and a value with zero rows produces no "
                "series rather than a zero. An empty table therefore means no client is in amber, "
                "and is the healthy state. It does NOT prove the gauge is wired: the red table "
                "beside it is the control that proves the pair is being published.",
                [prom("max by (client, flow) (dcre_sla_pending_amber)", "{{client}} {{flow}}",
                      instant=True, fmt="table")],
                w=12, h=7,
            ),
            table(
                "Latent files in the exchange",
                "Files sitting in a watched exchange directory, by client and directory. Latency "
                "here is the orchestrator's own view of unconsumed input. " + GAUGE_NOTE,
                [prom("max by (client, dir) (dcre_agt_latent_dir_files_total)",
                      "{{client}} {{dir}}", instant=True, fmt="table")],
                w=24, h=7,
            ),
        ],
    }


def jobs_dashboard() -> dict:
    return {
        "uid": "dcre-stage-jobs",
        "title": "DCRE Stage Jobs",
        "description": "What the batch jobs are doing, from two directions: the orchestrator's "
                       "view of what it launched and what came back, and the stage services' own "
                       "Spring Batch metrics. The orchestrator half reports today; the "
                       "self-reported half fills in when the fleet runs.",
        "tags": ["dcre", "generated"],
        "panels": [
            stat(
                "Stage services reporting",
                "Distinct dcre-<leaf> jobs that published a resource in the time range. "
                + STAGE_EMPTY_NOTE,
                [prom(f'count(count by (job) (max_over_time(target_info{{job=~"{STAGE_JOBS}"}}[$__range])))',
                      "stage services", instant=True)],
                thresholds=GREEN_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Abandoned launches",
                "Launch intents written and never converted into a running job. Any non-zero "
                "value is an orchestrator that promised a job it did not deliver. "
                + ZERO_NOTE + " " + GAUGE_NOTE,
                [prom(zero_when_live('max(agt_launch_intents_total{status="ABANDONED"})'), "abandoned",
                      instant=True)],
                thresholds=RED_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Intents awaiting launch",
                "Intents still in INTENDED. A number that stays put while nothing moves to "
                "LAUNCHED is the launch path stalled. " + ZERO_NOTE + " " + GAUGE_NOTE,
                [prom(zero_when_live('max(agt_launch_intents_total{status="INTENDED"})'), "intended",
                      instant=True)],
            ),
            stat(
                "Jobs launched",
                "Cumulative launches the orchestrator has observed starting. " + ZERO_NOTE + " "
                + GAUGE_NOTE,
                [prom(zero_when_live('max(agt_launch_intents_total{status="LAUNCHED"})'), "launched",
                      instant=True)],
            ),
            bargauge(
                "Launch intents by status",
                "The write-ahead launch ledger in one view. " + GAUGE_NOTE,
                [prom("max by (status) (agt_launch_intents_total)", "{{status}}", instant=True)],
                w=12, h=7,
            ),
            table(
                "Stage failure totals by class",
                "Every non-success stage outcome the orchestrator has recorded. TECH_CONFIG_FAILED "
                "is the class a crash-on-startup produces, which is what a broken migration looks "
                "like from here. " + GAUGE_NOTE,
                [prom('max by (outcome) (agt_stage_outcomes_total{outcome=~"TECH_.*|BUSINESS_FILE_REJECTED"})',
                      "{{outcome}}", instant=True, fmt="table")],
                thresholds=RED_ABOVE, color_mode="thresholds", w=12, h=7,
            ),
            timeseries(
                "Stage failures per second by class",
                "Rate of failing stage outcomes as they happen. " + COUNTER_NOTE,
                [prom('sum by (outcome) (rate(agt_stage_outcome_events_total{outcome=~"TECH_.*|BUSINESS_FILE_REJECTED"}[$__rate_interval]))',
                      "{{outcome}}")],
                w=12, h=8,
            ),
            timeseries(
                "Stage successes per second",
                "Rate of stage outcomes in the BUSINESS success classes, which are "
                "BUSINESS_ACCEPTED and BUSINESS_PARTIAL. " + COUNTER_NOTE,
                [prom('sum by (outcome) (rate(agt_stage_outcome_events_total{outcome=~"BUSINESS_ACCEPTED|BUSINESS_PARTIAL"}[$__rate_interval]))',
                      "{{outcome}}")],
                w=12, h=8,
            ),
            table(
                "Stage services and their telemetry series",
                "One row per reporting stage service. " + STAGE_EMPTY_NOTE,
                [prom(f'count by (job) (max_over_time(target_info{{job=~"{STAGE_JOBS}"}}[$__range]))',
                      "{{job}}", instant=True, fmt="table")],
                w=12, h=7,
            ),
            timeseries(
                "Orchestrator JVM heap used",
                "Heap of the orchestrator, split by pod. This panel is the CONTROL for the JVM "
                "panel beside it: the two are the same query against different jobs, so an empty "
                "stage panel next to a populated orchestrator panel means the stage fleet is "
                "down, and two empty panels mean something is wrong with the board.",
                [prom('sum by (host_name) (jvm_memory_used_bytes{job="agt", area="heap"})',
                      "{{host_name}}")],
                unit="bytes", w=12, h=8,
            ),
            timeseries(
                "Stage JVM heap used",
                "Heap of each stage service. " + STAGE_EMPTY_NOTE,
                [prom(f'sum by (job) (jvm_memory_used_bytes{{job=~"{STAGE_JOBS}", area="heap"}})',
                      "{{job}}")],
                unit="bytes", w=12, h=8,
            ),
            timeseries(
                "Spring Batch job executions, cumulative",
                "Completed Spring Batch job executions, split by job name and terminal status. "
                + BATCH_EPHEMERAL_NOTE + " " + SPRING_BATCH_NOTE,
                [prom(f'sum by (spring_batch_job_name, spring_batch_job_status) '
                      f'({{__name__=~"spring_batch_job_(milli)?seconds_count", job=~"{STAGE_JOBS}"}})',
                      "{{spring_batch_job_name}} {{spring_batch_job_status}}")],
                w=12, h=8,
            ),
            timeseries(
                "Spring Batch job duration, mean",
                "Mean wall time of a Spring Batch job execution, as total time over total "
                "executions. A p95 is NOT available: histogram_quantile reads bucket counts "
                "through rate(), which is empty here for the reason below. "
                + BATCH_EPHEMERAL_NOTE + " " + SPRING_BATCH_NOTE
                + " The unit is left unset because the bucket boundaries carry the upstream unit "
                "and forcing a unit here would mislabel one of the two renderings.",
                [prom(f'sum by (spring_batch_job_name) '
                      f'({{__name__=~"spring_batch_job_(milli)?seconds_sum", job=~"{STAGE_JOBS}"}}) '
                      f'/ sum by (spring_batch_job_name) '
                      f'({{__name__=~"spring_batch_job_(milli)?seconds_count", job=~"{STAGE_JOBS}"}})',
                      "{{spring_batch_job_name}}")],
                w=12, h=8,
            ),
            table(
                "Failed Spring Batch job executions",
                "Spring Batch job executions that ended FAILED, as a cumulative count rather than "
                "a count over the dashboard's range. " + BATCH_EPHEMERAL_NOTE + " "
                + SPRING_BATCH_NOTE,
                [prom(f'sum by (job, spring_batch_job_name) '
                      f'({{__name__=~"spring_batch_job_(milli)?seconds_count", job=~"{STAGE_JOBS}", spring_batch_job_status="FAILED"}})',
                      "{{job}} {{spring_batch_job_name}}", instant=True, fmt="table")],
                thresholds=RED_ABOVE, color_mode="thresholds", w=12, h=8,
            ),
            timeseries(
                "Spring Batch step executions, cumulative",
                "Step-level volume inside the jobs. " + BATCH_EPHEMERAL_NOTE + " "
                + SPRING_BATCH_NOTE,
                [prom(f'sum by (spring_batch_step_name) '
                      f'({{__name__=~"spring_batch_step_(milli)?seconds_count", job=~"{STAGE_JOBS}"}})',
                      "{{spring_batch_step_name}}")],
                w=12, h=8,
            ),
        ],
    }


def traces_dashboard() -> dict:
    return {
        "uid": "dcre-traces",
        "title": "DCRE Traces",
        "description": "Span throughput and latency from Tempo's metrics generator, plus live "
                       "TraceQL searches into Tempo itself. The span metrics carry a service "
                       "label rather than a job label, because they are generated by Tempo from "
                       "spans and not exported by the service.",
        "tags": ["dcre", "generated"],
        "panels": [
            stat(
                "Collector spans accepted per second",
                "Spans the OTLP collector accepted. This is the ingest side of the trace "
                "pipeline: zero here while services are running means spans are not reaching the "
                "collector at all, which no panel further down the board could distinguish from "
                "a quiet fleet.",
                [prom("sum(rate(otelcol_receiver_accepted_spans_total[$__rate_interval]))",
                      "accepted")],
            ),
            stat(
                "Collector spans refused per second",
                "Spans the collector REFUSED. Any sustained non-zero value is telemetry being "
                "dropped at the door, and it is invisible in every other panel on this board "
                "because the refused spans never become span metrics or traces.",
                [prom("sum(rate(otelcol_receiver_refused_spans_total[$__rate_interval]))",
                      "refused")],
                thresholds=RED_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Collector spans exported per second",
                "Spans the collector handed on to Tempo. A gap between accepted and exported is "
                "the collector's own queue backing up.",
                [prom("sum(rate(otelcol_exporter_sent_spans_total[$__rate_interval]))", "sent")],
            ),
            stat(
                "Collector export queue size",
                "Depth of the collector's export queue. A queue that climbs and does not drain is "
                "the backend refusing work, and the next thing to fail is silent span loss.",
                [prom("max(otelcol_exporter_queue_size)", "queue", instant=True)],
            ),
            timeseries(
                "Span rate by span name",
                "Calls per second for each span name, from Tempo's span metrics generator. "
                "Grouped by span_name and service, which are the generator's own labels: these "
                "series carry no job label, so a job-based filter would empty this panel.",
                [prom(f'sum by (service, span_name) (rate(traces_spanmetrics_calls_total{{service=~"{FLEET_JOBS}"}}[$__rate_interval]))',
                      "{{service}} {{span_name}}")],
                w=12, h=8,
            ),
            timeseries(
                "Span latency, p95",
                "95th percentile span duration per span name. Tempo's generator emits these "
                "buckets in SECONDS, which is why the unit here is seconds and not the "
                "milliseconds that Micrometer's own timers use elsewhere in this Grafana.",
                [prom(f'histogram_quantile(0.95, sum by (le, span_name) (rate(traces_spanmetrics_latency_bucket{{service=~"{FLEET_JOBS}"}}[$__rate_interval])))',
                      "{{span_name}}")],
                unit="s", w=12, h=8,
            ),
            bargauge(
                "Spans in the window by service",
                "Total spans generated per service across the dashboard's time range. Reads one "
                "bar while only the orchestrator traces; one bar per tracing service afterwards.",
                [prom(f'sum by (service) (increase(traces_spanmetrics_calls_total{{service=~"{FLEET_JOBS}"}}[$__range]))',
                      "{{service}}", instant=True)],
                w=12, h=7,
            ),
            timeseries(
                "Span error rate",
                "Spans whose status_code is STATUS_CODE_ERROR. EXPECTED EMPTY at generation "
                "time: every span in Tempo on 2026-09-11 carried STATUS_CODE_UNSET, so there is "
                "no error series to draw. Empty means no span has reported an error status in the "
                "window; the span rate panel above is the control that proves spans are arriving "
                "at all.",
                [prom(f'sum by (service, span_name) (rate(traces_spanmetrics_calls_total{{service=~"{FLEET_JOBS}", status_code="STATUS_CODE_ERROR"}}[$__rate_interval]))',
                      "{{service}} {{span_name}}")],
                w=12, h=7,
            ),
            table(
                "Recent traces",
                "Live TraceQL search into Tempo for anything this fleet emitted. Click a trace id "
                "to open the trace view. Measured returning traces on 2026-09-11.",
                [tempo(f'{{resource.service.name=~"{FLEET_JOBS}"}}')],
                w=12, h=9,
            ),
            table(
                "Traces carrying a DCRE arrival id",
                "Traces whose spans carry the dcre.arrival.id attribute, which is the identifier "
                "that ties a trace back to a file arrival. This is the panel to use when a "
                "specific file is in question: edit the query to "
                "{span.dcre.arrival.id = \"<id>\"}. Measured returning traces on 2026-09-11.",
                [tempo('{span.dcre.arrival.id != ""}')],
                w=12, h=9,
            ),
            table(
                "Slow traces, over one second",
                "TraceQL search for spans longer than a second. EXPECTED EMPTY at generation "
                "time: the same search returned 0 traces on 2026-09-11 while the unfiltered "
                "search returned traces, so nothing this fleet did took a second. Empty means "
                "fast, not broken, and the Recent traces panel is the control.",
                [tempo(f'{{resource.service.name=~"{FLEET_JOBS}" && duration > 1s}}')],
                w=12, h=9,
            ),
            table(
                "Errored traces",
                "TraceQL search for spans with an error status. EXPECTED EMPTY at generation "
                "time, for the same reason as the span error rate panel: every span carried "
                "STATUS_CODE_UNSET. The Recent traces panel is the control.",
                [tempo(f'{{resource.service.name=~"{FLEET_JOBS}" && status = error}}')],
                w=12, h=9,
            ),
        ],
    }


def logs_dashboard() -> dict:
    return {
        "uid": "dcre-logs",
        "title": "DCRE Logs",
        "description": "Log volume and the failure lines themselves, from Loki. Loki indexes only "
                       "service_name here; detected_level, host_name and the code location arrive "
                       "as structured metadata and are filtered with a pipeline stage rather than "
                       "a stream selector.",
        "tags": ["dcre", "generated"],
        "panels": [
            stat(
                "Error lines in the window",
                "Log lines at error level across the whole fleet. Counted with count_over_time "
                "over the dashboard's range, so the number moves with the time picker.",
                [loki(f'sum(count_over_time({{service_name=~"{FLEET_JOBS}"}} | detected_level=`error` [$__range])) or vector(0)',
                      "errors", instant=True, query_type="instant")],
                thresholds=RED_ABOVE, color_mode="thresholds",
            ),
            stat(
                "Warning lines in the window",
                "Log lines at warn level across the whole fleet.",
                [loki(f'sum(count_over_time({{service_name=~"{FLEET_JOBS}"}} | detected_level=`warn` [$__range])) or vector(0)',
                      "warnings", instant=True, query_type="instant")],
            ),
            stat(
                "Total lines in the window",
                "Every log line the fleet shipped in the range. This is the control for the two "
                "level panels beside it: zero errors with zero total lines means logging has "
                "stopped, which is a different fault from zero errors with a healthy total.",
                [loki(f'sum(count_over_time({{service_name=~"{FLEET_JOBS}"}}[$__range])) or vector(0)',
                      "lines", instant=True, query_type="instant")],
            ),
            stat(
                "Collector log records accepted per second",
                "Log records the OTLP collector accepted. Zero here while services are running "
                "means logs are not reaching the collector, which the Loki panels cannot "
                "distinguish from a silent fleet.",
                [prom("sum(rate(otelcol_receiver_accepted_log_records_total[$__rate_interval]))",
                      "accepted")],
            ),
            timeseries(
                "Log lines by level",
                "Log volume split by Loki's detected_level. A level that vanishes from this panel "
                "has stopped being emitted; a level that spikes is the thing to open next.",
                [loki(f'sum by (detected_level) (count_over_time({{service_name=~"{FLEET_JOBS}"}}[$__auto]))',
                      "{{detected_level}}")],
                w=12, h=8,
            ),
            timeseries(
                "Log lines by service",
                "Log volume split by service. Reads one series while only the orchestrator is up, "
                "and one per stage service afterwards; a stage service that starts and then stops "
                "logging is visible here before it is visible anywhere else.",
                [loki(f'sum by (service_name) (count_over_time({{service_name=~"{FLEET_JOBS}"}}[$__auto]))',
                      "{{service_name}}")],
                w=12, h=8,
            ),
            timeseries(
                "Stage outcome lines by class",
                "The orchestrator logs one line per stage outcome. This panel extracts the "
                "outcome class out of the line itself, so it reports what was WRITTEN rather than "
                "what was counted, and disagreement between this panel and the outcome counters "
                "on the Stage Jobs board means one of the two paths is dropping events. The line "
                "filter runs before the regexp so lines carrying no class cannot contribute an "
                "unlabelled series.",
                [loki('sum by (class) (count_over_time({service_name=`agt`} '
                      '|~ `(TECH_|BUSINESS_)[A-Z_]+` '
                      '| regexp `(?P<class>(?:TECH_|BUSINESS_)[A-Z_]+)` [$__auto]))',
                      "{{class}}")],
                w=12, h=8,
            ),
            timeseries(
                "Error and warning lines per second",
                "Rate of the two levels worth waking up for, across the fleet.",
                [loki(f'sum by (detected_level) (count_over_time({{service_name=~"{FLEET_JOBS}"}} '
                      f'| detected_level =~ `error|warn` [$__auto]))',
                      "{{detected_level}}")],
                w=12, h=8,
            ),
            logs(
                "Error and warning lines",
                "The lines themselves, newest first. Expand a line to see its structured "
                "metadata: host_name names the pod, and code_function_name with code_line_number "
                "names the site in the source.",
                [loki(f'{{service_name=~"{FLEET_JOBS}"}} | detected_level =~ `error|warn`')],
            ),
            logs(
                "Stage failure outcome lines",
                "Every orchestrator line naming a TECH_ or BUSINESS_ outcome class, newest first. "
                "This is where a stage crash says WHY: the line carries the Kubernetes reason and "
                "the container exit code beside the class.",
                [loki('{service_name=`agt`} |~ `(TECH_|BUSINESS_)[A-Z_]+`')],
            ),
        ],
    }


DASHBOARDS = [overview_dashboard, jobs_dashboard, traces_dashboard, logs_dashboard]


# --------------------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------------------

def cross_links() -> list[dict]:
    """Dashboard-to-dashboard links carrying the time range, so a reader who finds a
    spike on one board lands on the same window of the next."""
    return [{
        "asDropdown": False,
        "icon": "external link",
        "includeVars": False,
        "keepTime": True,
        "tags": ["dcre"],
        "targetBlank": False,
        "title": "DCRE boards",
        "tooltip": "Every DCRE board, at this time range",
        "type": "dashboards",
        "url": "",
    }]


def lay_out(panels: list[dict]) -> list[dict]:
    """Pack panels left to right into a 24-column grid, wrapping on overflow."""
    out, x, y, row_h = [], 0, 0, 0
    for i, p in enumerate(panels):
        p = dict(p)
        w, h = p.pop("w"), p.pop("h")
        if x + w > 24:
            x, y, row_h = 0, y + row_h, 0
        p["gridPos"] = {"h": h, "w": w, "x": x, "y": y}
        p["id"] = i + 1
        x += w
        row_h = max(row_h, h)
        out.append(p)
    return out


def render_dashboard(build) -> dict:
    d = build()
    return {
        "uid": d["uid"],
        "title": d["title"],
        "description": d["description"] + " GENERATED by scripts/obs-dashboards.py; edits made "
                                          "here are overwritten on the next provisioning cycle.",
        "tags": d["tags"],
        "timezone": "browser",
        "editable": False,
        "graphTooltip": 1,
        "schemaVersion": 39,
        "refresh": "30s",
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {},
        "templating": {"list": []},
        "links": cross_links(),
        "annotations": {"list": []},
        "panels": lay_out(d["panels"]),
    }


def provider_yaml() -> str:
    return (
        "apiVersion: 1\n"
        "\n"
        "providers:\n"
        "  - name: dcre-obs\n"
        "    orgId: 1\n"
        f"    folder: {GRAFANA_FOLDER}\n"
        "    type: file\n"
        "    disableDeletion: false\n"
        "    # Read-only in the UI, which is what makes every dashboard here report\n"
        "    # meta.provisioned true. Changing a panel means changing the generator.\n"
        "    allowUiUpdates: false\n"
        "    updateIntervalSeconds: 30\n"
        "    options:\n"
        f"      path: {DASHBOARD_DIR_IN_POD}\n"
        "      foldersFromFilesStructure: false\n"
    )


def dashboard_files() -> dict[str, str]:
    files = {"dcre-provider.yaml": provider_yaml()}
    for build in DASHBOARDS:
        d = render_dashboard(build)
        files[f"{d['uid']}.json"] = json.dumps(d, indent=2, sort_keys=True) + "\n"
    return files


def render_configmap() -> str:
    files = dashboard_files()
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
        "    app.kubernetes.io/component: dashboards",
        "data:",
    ]
    for name in sorted(files):
        lines.append(f"  {name}: |")
        for line in files[name].rstrip("\n").split("\n"):
            lines.append(f"    {line}" if line else "")
    return "\n".join(lines) + "\n"


def check_manifests() -> list[str]:
    """The Deployment's `items` lists name every dashboard file BY NAME, and so does this
    generator. That is two homes for one fact, and its failure is silent: add a fifth
    dashboard here, forget the manifest, and the file simply never mounts, the board
    simply never appears, and nothing anywhere goes red. This turns the manifest into a
    CHECKED CONSUMER instead of a second source, so the omission fails the gate.

    Returns a list of findings; empty means the manifests agree with the generator.
    """
    findings: list[str] = []
    if not DEPLOYMENT.exists():
        return [f"{DEPLOYMENT} does not exist"]
    dep = DEPLOYMENT.read_text()
    keys = sorted(dashboard_files())

    if f"name: {CONFIGMAP_NAME}" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not reference ConfigMap {CONFIGMAP_NAME}")
    if f"mountPath: {DASHBOARD_DIR_IN_POD}" not in dep:
        findings.append(f"{DEPLOYMENT.name} does not mount {DASHBOARD_DIR_IN_POD}")
    for key in keys:
        if f"- key: {key}" not in dep:
            findings.append(f"{DEPLOYMENT.name} does not project ConfigMap key {key}")
        if f"path: {key}" not in dep:
            findings.append(f"{DEPLOYMENT.name} does not give {key} a projected path")

    # A STALE entry is as silent as a missing one, in the other direction: a key removed
    # from the generator but left in the manifest makes the pod refuse to start only if
    # the key is required, and otherwise just sits there lying. Count both lists.
    # Scoped to THIS ConfigMap's own volume blocks. A flat sweep of every `- key:` line
    # in the Deployment was wrong the moment a second generated ConfigMap arrived beside
    # this one (06-obs-alerting.yml, 2026-09-11): it read the alerting keys as stale
    # dashboard keys and failed a gate that had nothing to complain about. A guard that
    # goes red on a neighbour's correct work is a guard people learn to ignore.
    projected, in_this_configmap = [], False
    for ln in dep.splitlines():
        stripped = ln.strip()
        if stripped.startswith("- name: "):
            in_this_configmap = False          # a new volume; ownership is re-decided below
        elif stripped == f"name: {CONFIGMAP_NAME}":
            in_this_configmap = True
        elif stripped.startswith("name: ") and stripped != f"name: {CONFIGMAP_NAME}":
            in_this_configmap = False
        elif in_this_configmap and stripped.startswith("- key: "):
            projected.append(stripped[len("- key: "):])
    stale = sorted(set(projected) - set(keys))
    if stale:
        findings.append(f"{DEPLOYMENT.name} projects keys this generator does not emit: "
                        f"{', '.join(stale)}")

    if KUSTOMIZATION.exists() and ARTIFACT.name not in KUSTOMIZATION.read_text():
        findings.append(f"{KUSTOMIZATION.name} does not list {ARTIFACT.name} under resources")
    return findings


# --------------------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------------------

SUBSTITUTIONS = [
    ("$__rate_interval", "5m"),
    ("$__range", "6h"),
    ("$__auto", "5m"),
    ("$__interval", "1m"),
]


def concrete(expr: str) -> str:
    for token, value in SUBSTITUTIONS:
        expr = expr.replace(token, value)
    return expr


def http_json(url: str, timeout: int = 60):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.load(r), None
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace")
        return None, f"HTTP {e.code}: {body}"
    except Exception as e:  # noqa: BLE001 - the message is the finding
        return None, f"{type(e).__name__}: {e}"


def verify_target(grafana: str, t: dict) -> tuple[str, str]:
    """Return (verdict, detail). Verdict is one of DATA, EMPTY, ERROR."""
    uid = t["datasource"]["uid"]
    if uid == "prometheus":
        url = (f"{grafana}/api/datasources/proxy/uid/prometheus/api/v1/query?"
               + urllib.parse.urlencode({"query": concrete(t["expr"])}))
        d, err = http_json(url)
        if err:
            return "ERROR", err
        if d.get("status") != "success":
            return "ERROR", f"{d.get('errorType')}: {d.get('error')}"
        n = len(d["data"]["result"])
        return ("DATA" if n else "EMPTY"), f"{n} series"
    if uid == "loki":
        # Run each target the way GRAFANA will run it. A log-stream query is a RANGE
        # query and Loki rejects it outright as an instant query ("log queries are not
        # supported as an instant query type"), so a verifier that sent everything to
        # the instant endpoint would report a working panel as an error. Found by this
        # verifier on its first run, 2026-09-11; the panels were correct and the
        # instrument was not.
        now = time.time()
        if t.get("queryType") == "instant":
            url = (f"{grafana}/api/datasources/proxy/uid/loki/loki/api/v1/query?"
                   + urllib.parse.urlencode({"query": concrete(t["expr"]),
                                             "time": int(now * 1e9), "limit": 5}))
        else:
            url = (f"{grafana}/api/datasources/proxy/uid/loki/loki/api/v1/query_range?"
                   + urllib.parse.urlencode({"query": concrete(t["expr"]),
                                             "start": int((now - 6 * 3600) * 1e9),
                                             "end": int(now * 1e9),
                                             "step": "60s", "limit": 20}))
        d, err = http_json(url)
        if err:
            return "ERROR", err
        if d.get("status") != "success":
            return "ERROR", json.dumps(d)[:200]
        n = len(d["data"]["result"])
        return ("DATA" if n else "EMPTY"), f"{n} {d['data']['resultType']}"
    if uid == "tempo":
        end = int(time.time())
        url = (f"{grafana}/api/datasources/proxy/uid/tempo/api/search?"
               + urllib.parse.urlencode({"q": t["query"], "limit": t.get("limit", 20),
                                         "start": end - 6 * 3600, "end": end}))
        d, err = http_json(url)
        if err:
            return "ERROR", err
        n = len(d.get("traces") or [])
        return ("DATA" if n else "EMPTY"), f"{n} traces"
    return "ERROR", f"unknown datasource uid {uid!r}"


def verify(grafana: str) -> int:
    # Fail closed: the health probe must answer 200 with a version, or nothing below
    # is a measurement of anything. An unreachable Grafana must not read as "no errors".
    d, err = http_json(f"{grafana}/api/health", timeout=15)
    if err or not (d or {}).get("version"):
        print(f"REFUSED: {grafana}/api/health did not answer ({err or d})", file=sys.stderr)
        return 2
    print(f"verifying against {grafana} (Grafana {d['version']})")

    errors, empties, data = [], [], []
    for build in DASHBOARDS:
        dash = render_dashboard(build)
        print(f"\n=== {dash['title']}  [{dash['uid']}]")
        for p in dash["panels"]:
            for t in p["targets"]:
                verdict, detail = verify_target(grafana, t)
                expr = t.get("expr") or t.get("query")
                row = (dash["uid"], p["title"], expr, detail)
                {"ERROR": errors, "EMPTY": empties, "DATA": data}[verdict].append(row)
                print(f"  {verdict:5s} {p['title'][:48]:50s} {detail}")
                if verdict == "ERROR":
                    print(f"        query: {expr}")
                    print(f"        error: {detail}")

    total = len(errors) + len(empties) + len(data)
    print(f"\n{'-' * 78}")
    print(f"targets: {total}   DATA: {len(data)}   EMPTY: {len(empties)}   ERROR: {len(errors)}")
    if empties:
        print("\nEMPTY targets (each must be explained in its own panel description):")
        for uid, title, expr, _ in empties:
            print(f"  {uid} / {title}")
    if errors:
        print("\nREFUSING TO PUBLISH: a panel query returned an error.", file=sys.stderr)
        for uid, title, expr, detail in errors:
            print(f"  {uid} / {title}: {detail}\n    {expr}", file=sys.stderr)
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
                    help="run every panel target against the live datasources")
    ap.add_argument("--grafana", default="http://localhost:3011",
                    help="Grafana base URL for --verify (default: http://localhost:3011)")
    args = ap.parse_args()

    if args.verify:
        return verify(args.grafana.rstrip("/"))

    rendered = render_configmap()
    if args.check:
        if not ARTIFACT.exists():
            print(f"DRIFT: {ARTIFACT} does not exist", file=sys.stderr)
            return 1
        committed = ARTIFACT.read_text()
        if committed != rendered:
            print(f"DRIFT: {ARTIFACT} differs from scripts/obs-dashboards.py.", file=sys.stderr)
            print("Re-run `python3 scripts/obs-dashboards.py` and commit the result.",
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
        n_panels = sum(len(render_dashboard(b)["panels"]) for b in DASHBOARDS)
        print(f"OK: {ARTIFACT.relative_to(REPO_ROOT)} matches the generator "
              f"({len(DASHBOARDS)} dashboards, {n_panels} panels), and "
              f"{DEPLOYMENT.name} projects all {len(dashboard_files())} ConfigMap keys")
        return 0

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(rendered)
    n_panels = sum(len(render_dashboard(b)["panels"]) for b in DASHBOARDS)
    print(f"wrote {ARTIFACT.relative_to(REPO_ROOT)} "
          f"({len(DASHBOARDS)} dashboards, {n_panels} panels, {len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
