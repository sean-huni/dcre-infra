# dcre-infra

> Part of the DCRE fleet. For the fleet map, the rulings and the diagrams that specify every stage, start at the [DCRE design register](https://github.com/sean-huni/dcre-design-register); the complete list of live repositories is its [Repositories](https://github.com/sean-huni/dcre-design-register/blob/dev/README.md#repositories) table.

Dev infrastructure for DCRE Collections 3.0: kind cluster, CockroachDB, the per-client exchange tree, LGTM observability, fleet runbook scripts and the Fintegrate simulator.

## What it does

Provides the two local environments the DCRE fleet (the Spring Batch stage services, whose roster is AGT's `Stage` enum, plus the Quarkus AGT orchestrator) runs against: a Docker Compose inner loop and a kind cluster for pipeline DevTesting, both on the same images (dev/prod parity). It also carries the operational runbooks as scripts: 13-step clean-slate reset, fleet release switcher with downgrade guards, port-forward self-healing, and the Fintegrate reply simulator that closes the pain.008 to pain.002-family loop.

- **Compose (inner loop):** `docker compose up -d` gives CockroachDB (SQL 26257, DB Console 8081) and grafana/otel-lgtm (Grafana 3000, OTLP 4317/4318).
- **kind (pipeline DevTesting):** `./scripts/kind-up.sh` creates cluster `dcre-dev` with the control namespace `dcre` and the flow namespaces `dcre-col`, `dcre-pay` and `dcre-man`, AGT RBAC in all four, in-cluster CockroachDB and LGTM, and the `dcre-exchange` PVC backed by this repo's `exchange/` dir (drop a file locally, pods see it).

## Architecture and principles

- **SOLID, applied here:** one script per responsibility (`crdb-forward.sh` only forwards, `lgtm-up.sh` only revives the observability stack, `env-reset.sh` only resets); each is standalone and idempotent, and `kind-up.sh` composes them instead of duplicating them. Manifests (`k8s/base`, kustomize), scripts, and fixtures are separate seams.
- **12FactorApp Alignment - https://12factor.net/:** config strictly from the environment (`.env.example` documents the committed working defaults; clean-clone rule: everything runs with NO `.env`, the file is the override point); dev/prod parity (identical `cockroachdb/cockroach:v26.2.3` and `grafana/otel-lgtm:0.29.0` images in compose and kind); backing services as attached resources (DB via JDBC URL, telemetry via `OTEL_EXPORTER_OTLP_ENDPOINT`); stage services are stateless one-shot processes minted as k8s Jobs by AGT.
- **Idempotent restart semantics:** `crdb-init.sql` is guarded (`CREATE DATABASE IF NOT EXISTS`, never DROP); `seed-liquibase-history.sql` is `IF NOT EXISTS` throughout; the forward scripts kill-and-restart safely; `env-reset.sh` step ordering is load-bearing (AGT down first, schema-change job drain before seeding, Liquibase history verified before any service returns).
- **Guard rails over convention:** `switch-version.sh` refuses fleet downgrades that would durably poison data (2.0 boundary, 2.0.1 A-45 fix, and one-directional minor lines from 2.1: per-client tree and attempt schema, 2.2 flow namespaces, 2.3 mandates stages).

## Exchange directory contract (R-30/R-31, per-client SCRUM-42)

Client-first layout under the single exchange root: `exchange/<clientbase>/<channel>/<sub>`, with `clientbase` lowercase for each client in scope (`fnbcc01`, `fnbcc02`, `fnbrf01`). Each channel has its `in`/`out`/`error`/`archive` lifecycle subdirs:

- `onhost-req` (in/error/archive): inbound copybooks; filenames carry client + MsgId; AGT watches `in`.
- `onhost-req-endo` (in/error/archive): inbound ENDO Payments DAG (`PRR -> PTV -> PAI -> {PRW, PIR}`, per AGT's `RouteDags`, checked 2026-09-28).
- `onhost-resp` (out/error/archive): CIR/PRG output.
- `fint-req` (out/error/archive): CRW pain.008; fint-sim consumes `out`.
- `fint-resp` (in/error/archive): pain.002-family; fint-sim drops `in`; AGT watches.
- `onhost-req-man` (in/error/archive): inbound mandate instruction books (M10 mandates route).
- `onhost-resp-man` (out/error/archive): mandate outcome output (M10 mandates route).
- `fint-req-man` (out/error/archive): outbound mandate requests to Fintegrate (M10 mandates route).
- `fint-resp-man` (in/error/archive): inbound mandate responses from Fintegrate (M10 mandates route).

Under the inbound channels (`onhost-req`, `onhost-req-endo`, `fint-resp`, `onhost-req-man`, `fint-resp-man`), `archive` also hosts AGT's nested `inflight/` and `duplicates/` sinks.

Two seams stay **global** (outside the per-client tree, directly under the exchange root): `outcomes` (M1/M2 synthetic AGT-service outcome seam, SYNTHETIC-CONTRACT) and `chaos` (test fault injection).

## Prerequisites

- Docker with Compose v2
- kind and kubectl (manifests apply with `kubectl apply -k`)
- zsh (all scripts) and python3 (`fint_sim_reply.py`)

## Quickstart

Clean clone works with NO `.env` (committed defaults):

```bash
git clone https://github.com/sean-huni/dcre-infra.git
cd dcre-infra

# Inner loop: CRDB + LGTM on the host
docker compose up -d

# Pipeline DevTesting: kind cluster dcre-dev (CRDB + LGTM in-cluster, forwards started)
./scripts/kind-up.sh

# Tear the cluster down (kills the forwards on 3001/26258 first)
./scripts/kind-down.sh
```

Host ports:

| Endpoint | Compose | kind (forwarded) |
|---|---|---|
| CRDB SQL | 26257 | 26258 (`scripts/crdb-forward.sh`) |
| CRDB DB Console | 8081 | 8081 (`scripts/crdb-forward.sh`) |
| Grafana | 3000 | 3001 (`scripts/lgtm-forward.sh`) |
| OTLP gRPC / HTTP | 4317 / 4318 | in-cluster `svc/lgtm` |

Databases `dcre_col`, `agt_ops` and `dcre_man` are created by `scripts/crdb-init.sql` (guarded, never DROP) in both environments. **`dcre_pay` and `dcre_hcs` are not created by anything in this repository**, although AGT's committed defaults address both (checked 2026-09-28); create them by hand (`CREATE DATABASE IF NOT EXISTS dcre_pay;`, same for `dcre_hcs`) before running payments stages or HCS.

**Migration note (pre-existing environments):** the initdb path (compose mount, k8s `crdb-init` ConfigMap) runs on FIRST bootstrap only; an environment that already has a CRDB volume or a live cluster does not re-run it. Such environments pick up `dcre_man` via `env-reset.sh` step 4, or manually: `CREATE DATABASE IF NOT EXISTS dcre_man;`.

## Configuration

All values have committed working defaults (`.env.example`); copy to `.env` only to override.

| Variable | Default | Purpose |
|---|---|---|
| `DCRE_DB_URL` | `jdbc:postgresql://localhost:26257/dcre_col?sslmode=disable` | Stage-service JDBC URL |
| `AGT_DB_URL` | `jdbc:postgresql://localhost:26257/agt_ops?sslmode=disable` | AGT ops JDBC URL |
| `DCRE_EXCHANGE_ROOT` | `./exchange` | Single exchange root; the per-client tree lives under it |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | OTLP ingest (LGTM) |

## Scripts (runbooks)

| Script | Purpose |
|---|---|
| `kind-up.sh` | Create `dcre-dev`, pre-pull and archive-load `grafana/otel-lgtm:0.29.0` (kind issue 3510 workaround for the containerd image store), apply `k8s/base`, wait for CRDB/LGTM rollouts, start both forwards |
| `kind-down.sh` | Kill the forwards, delete the cluster |
| `crdb-forward.sh` | Idempotent CRDB port-forward: SQL 26258, DB Console 8081 (matches the compose mapping) |
| `lgtm-forward.sh` | Idempotent Grafana forward: host 3001 (3000 stays reserved for compose LGTM) |
| `lgtm-up.sh` | Revive the compose LGTM container with a Grafana health wait (OTLP exporters fail open, so a dead collector drops telemetry silently) |
| `grafana-provision.sh` | Idempotent client-stats provisioning against the in-cluster Grafana (:3001): 4 orgs (FNBCC01, FNBCC02, FNBRF01, FNB Internal), one Editor login per org (dev password `devdev`), and per-org CockroachDB datasources scoped to that client's DB role (`dcre-rpt`; FNB Internal also gets `dcre-ops` on `agt_ops`). Basic-auth admin API; removes each client from Main Org so its sole membership is its own org |
| `grafana-dashboards.sh` | Posts two dashboard packs (fixed UIDs, `overwrite:true`, idempotent): `dcre-client-stats` to every org (session-identity portability: one JSON renders per-client via each org's scoped datasource) and `dcre-internal-stats` to FNB Internal only |
| `rpt-accuracy-check.sh` | 54-check accuracy matrix: independent raw-SQL derivation from base tables (as `root`) vs the rpt views the dashboards display (as each client / `rpt_internal`); fail-closed (empty/non-numeric FAILS), exits non-zero on any mismatch (spec gate) |
| `rpt-security-probes.sh` | Negative security probes: grants wall (client role denied on `public.*` and ops views, asserting SQLSTATE 42501) plus per-view cross-client scoping and a non-emptiness canary; exits non-zero on any unexpected access |
| `grafana-screenshots.mjs` | Playwright (headless chromium) evidence capture: logs in as each org user and screenshots every dashboard, proving per-client isolation and full panel rendering (tall viewport so lazy panels paint). Manifest: `scripts/package.json` |
| `env-reset.sh [--seed accounts.sql mandates.sql]` | 13-step clean slate: stop AGT, delete Jobs/pods, stop fint-sim, drop+recreate the three DBs it knows (`dcre_col`, `agt_ops`, `dcre_man`; not `dcre_pay` or `dcre_hcs`), drain CRDB schema-change jobs, pre-seed and verify all 46 Liquibase history+lock tables (24 in `dcre_col`, 20 in `dcre_man`, 2 `rpt_*` in `agt_ops`), clean the exchange, restart AGT, optional reference reseed, warm-up drops per route, post-checks, restart fint-sim |
| `switch-version.sh <1.0\|1.1\|2.0\|2.0.1\|2.1.0\|2.2.0\|2.3.0>` | Fleet-wide release switch: sets the AGT image and an `AGT_<STAGE>_IMAGE` env for CRR CTV CIR CDE CRW IXR SXR PXR PRG AIS HCS, plus MRR MRV MAS MIT MIR MRW MIX MSX MPX MRG from 2.3; refuses 2.0.x to 1.x, 2.0.1 to 2.0, and any move to a lower major.minor line. The stage list predates AGT's current roster (see Known defects below) |
| `fint-sim.sh` + `fint_sim_reply.py` | Fintegrate simulator: per client, polls `fint-req/out` for `*_PAIN008.xml`, replies with `{client}_{msgId}_ISR/SBSR/PBSR.xml` into `fint-resp/in` (atomic tmp+rename; every 4th tx RJCT with Rsn AC04), archives the request. M10 mandates leg (`--mandate`): polls `fint-req-man/out` for the mrw outbound `*_PAIN009/010/011.xml` and replies with a pain.012 `ISR`(ACCP)/`SBSR`(PDNG)/`PBSR` trio into `fint-resp-man/in`; PBSR is ACCP, except every 4th mandate RJCT with a rotating reason (AC01/AC04/MD01/MS03) and every 7th a delayed debtor-auth (PDNG then a second `-AUTH_PBSR.xml` ACCP after `--auth-delay-seconds`). Fault selection is a stable digest of the MndtReqId, so replays are byte-identical |
| `test_fint_sim_reply.py` | Stdlib verification suite for `fint_sim_reply.py` (mandate trio, reason rotation, delayed-auth, replay-idempotency, collections regression): `python3 scripts/test_fint_sim_reply.py` |
| `crdb-init.sql` | Guarded creation of `dcre_col`, `agt_ops` and `dcre_man` |
| `seed-liquibase-history.sql` | Pre-creates every module's Liquibase history+lock tables (first-run bootstrap-race guard, idempotent) |
| `file-trace-query.sql` | The saved cross-DB file-name killer query (SCRUM-58): resolve ANY boundary filename to client/direction/kind/route + ordered step timeline. Run as `rpt_internal`; substitute `:fname`. See the trace runbook below |
| `audit-file-trace.sh` | Trace-resolution audit gate (SCRUM-58): every exchange file must resolve to >= 1 row from the killer query; exits non-zero listing any untraceable file. Called by the chaos harness as a post-run gate step |

## Local cluster deployment

Stage images are built in each service repo, then loaded into the cluster; AGT (deployment `dcre-agt`, ServiceAccount `dcre-agt` with RBAC to create, watch and delete batch Jobs and read pods in `dcre`, `dcre-col`, `dcre-pay` and `dcre-man`, plus configmaps and secrets in `dcre`; no `pods/log`) mints them as short-lived k8s Jobs, one per stage execution:

```bash
# In each stage-service repo: build, image, load
./gradlew bootJar && docker build -t dcre-SVC:TAG . && kind load docker-image --name dcre-dev dcre-SVC:TAG
# AGT (Quarkus, Alpine production image per the fleet's Alpine-only standing rule):
./gradlew build && docker build -f src/main/docker/Dockerfile.jvm.prod -t dcre-agt:TAG .

# Back here: switch the whole fleet to a release (never mixed versions)
./scripts/switch-version.sh 2.1.0

# Clean slate before a test round (optionally reseed reference data)
./scripts/env-reset.sh --seed accounts.sql mandates.sql

# Drop a fixture book from dcre-fixture-toolkit
cp FNBRF01_*.txt exchange/fnbrf01/onhost-req/in/
```

## Observability and client stats (M8)

Two Grafana instances run, deliberately kept separate:

- **In-cluster LGTM** (`grafana/otel-lgtm:0.29.0`, deployed by `k8s/base/04-lgtm.yml`, PVC-backed) is the pipeline-DevTesting target. AGT and the stage services export OTLP to the in-cluster collector at `lgtm:4317` (svc `lgtm`, SCRUM-52); Grafana is reached on the host at http://localhost:3001 via `scripts/lgtm-forward.sh` (host 3000 stays reserved for the compose LGTM).
- **Compose LGTM** (Grafana 3000, OTLP 4317/4318) stays for the inner loop: a separate, also-healthy Grafana. Do not cross the wires.

The ambient `GRAFANA_URL` (used by the Grafana MCP) points at the *compose* LGTM on :3000, so the client-stats scripts deliberately target :3001 explicitly (override with `DCRE_GRAFANA_URL`) rather than inherit it.

**Operational dashboards** (`dcre-pipeline` RED baseline, `dcre-agt` arrivals/intents/outcomes) are managed via the Grafana API/MCP, never hand-edited JSON; the in-cluster Grafana is PVC-backed so they survive pod restarts.

**Client self-service stats** (M8, SCRUM-50) are provisioned and verified deterministically by the scripts above, in order:

```bash
./scripts/lgtm-forward.sh          # Grafana on :3001
./scripts/crdb-forward.sh          # CRDB SQL on :26258 (probes/accuracy need it)
./scripts/grafana-provision.sh     # 4 orgs + per-role scoped datasources (login devdev)
./scripts/grafana-dashboards.sh    # client + internal dashboard packs
./scripts/rpt-security-probes.sh   # grants wall + cross-client scoping (exit 0 = pass)
./scripts/rpt-accuracy-check.sh    # 54-check accuracy matrix (exit 0 = pass)

# Screenshot evidence (Playwright; first run installs deps + the browser):
cd scripts && npm install && npx playwright install chromium
node grafana-screenshots.mjs
```

The captured M8 evidence (accuracy matrix, security probes, per-client screenshots, chaos + review notes) lives in the design-register repo under `docs/evidence/2026-07-15-client-stats/`.

## File-name trace (SCRUM-58 prod-support runbook)

A prod supporter who holds ANY boundary file name resolves it, in one saved query, to the client, direction, kind (format), route and the ordered step timeline. Owner modules persist every inbound and outbound file name write-ahead in their own tables; the `dcre-rpt` service owns two normalizing view pairs (`dcre_col.rpt.v_file_index` / `rpt.v_flow_trace` and `agt_ops.rpt.v_ops_file_index` / `rpt.v_ops_flow`); the killer query in `scripts/file-trace-query.sql` unions them across both databases.

**Why a saved statement and not a view:** a persisted cross-DB view needs the deprecated cluster-wide `sql.cross_db_views.enabled`, which stays OFF on the shared cluster. Ad-hoc 3-part-name (`<db>.rpt.<view>`) cross-DB SELECTs work by default, so the query runs from any database in the cluster.

**Run it (as `rpt_internal` or `root` only** -- the four views are gated `WHERE current_user IN ('rpt_internal','root')`, so client datasource roles see zero rows; cross-client file names are tenant leakage):

```bash
# Replace :fname with the bare basename as a single-quoted literal (cockroach sql has no :var binding).
FNAME='FNBCC01_DCRECC2026071410000001_onhost-req_RESP.txt'

# kind cluster:
sed "s/:fname/'${FNAME}'/g" scripts/file-trace-query.sql \
  | kubectl -n dcre exec -i crdb-0 -- ./cockroach sql --insecure --user=rpt_internal --database=dcre_col

# compose inner loop (CRDB on :26257):
sed "s/:fname/'${FNAME}'/g" scripts/file-trace-query.sql \
  | cockroach sql --insecure --host=localhost:26257 --user=rpt_internal --database=dcre_col
```

The `--database` is passed explicitly (ops-scripting discipline); the query itself resolves everything through fully-qualified 3-part names, so the connected database is otherwise irrelevant. The result is one ordered set: client, direction, kind, route, state, then the step timeline (`ARRIVED`/`QUARANTINED`/`DUPLICATE_REDELIVERY` and `<STAGE>_INTENDED`/`<STAGE>_<OUTCOME>` from the ops side interleaved with `CRR_INGESTED` -> `CTV_VALIDATED` -> `CIR_RESP_STAGED`/`WRITTEN` -> `CRW_PLANNED`/`CRW_VISIBLE` -> `IXR`/`SXR`/`PXR_REPLY` -> `PRG_REPORTED` -> `RPT_OUTCOME` from the business side).

**`error/` and `duplicates/` names:** those on-disk names carry a leading `<uuid>_` claim prefix, and after the quarantine row-id fix the uuid IS the arrival/claim id. The owner tables store the BARE name, so strip the `<uuid>_` prefix before pasting `:fname` (or paste the uuid straight into the `arr` CTE). `audit-file-trace.sh` strips it automatically.

**The audit gate (`audit-file-trace.sh`):** after an e2e / chaos run it enumerates every file under the exchange root, runs the killer query for each, and exits non-zero listing any file that returns zero rows (an untraceable boundary file = a capture-layer hole). It excludes `inflight/`, `*.tmp` and hidden markers (`.gitkeep`, `.reset-stamp`, `.staging-drop`) -- the non-deliverable / partial-write artifacts. The chaos harness invokes it as a post-run gate step:

```bash
scripts/audit-file-trace.sh || { echo "trace-resolution gate failed"; exit 1; }
```

Config is 12-factor (committed defaults target the kind cluster, matching `rpt-security-probes.sh`): `DCRE_EXCHANGE_ROOT` (or first arg), `DCRE_COCKROACH` (connection command prefix), `CRDB_USER` (default `rpt_internal`), `CRDB_DATABASE` (default `dcre_col`). Exit codes: `0` all files resolve, `1` one or more unresolved, `2` config error, `3` query/connection failure (fails closed -- a dead DB never false-passes). Override the connection for the inner loop, e.g. `DCRE_COCKROACH="cockroach sql --insecure --host=localhost:26257"`.

**Honest limitations (no backfill, by design):** pre-feature CIR RESP names and pre-feature duplicate re-deliveries stay as dark as they are today; legacy files of every other class trace immediately from existing owner columns. Dev-only `local-<svc>-<executionId>` seam names of the non-rpt modules are self-describing into batch metadata but are NOT killer-query-resolvable (only rpt's seam names are, via `rpt_run`).

## Testing

There is no CI pipeline in this repository and no `scripts/test-*.sh`. The checks it ships:

| Check | Needs | Run | Pass |
|---|---|---|---|
| `scripts/test_fint_sim_reply.py` | python3 only (stdlib `unittest`) | `python3 scripts/test_fint_sim_reply.py` | exit 0 |
| `scripts/rpt-security-probes.sh` | kind cluster, `crdb-forward.sh` running, rpt views deployed | `./scripts/rpt-security-probes.sh` | exit 0 |
| `scripts/rpt-accuracy-check.sh` | same as above, with data loaded | `./scripts/rpt-accuracy-check.sh` | exit 0 |
| `scripts/audit-file-trace.sh` | kind cluster (or `DCRE_COCKROACH` override), after an e2e or chaos run | `./scripts/audit-file-trace.sh` | exit 0; 1 = untraceable files, 2 = config error, 3 = query failure |

Only the first runs without a database. The other three are gates against a live CockroachDB, described in their sections above.

## Known defects (checked 2026-09-28)

- `crdb-init.sql` and `env-reset.sh` create three databases; AGT addresses five (`dcre_pay` and `dcre_hcs` are missing).
- `switch-version.sh` sets image envs for IXR SXR PXR AIS, which are not in AGT's current `Stage` roster, and sets none for CIX CSX CPX CRG or any payments stage (PRR PTV PAI PRW PIR PIX PSX PPX).

## Related repositories

The complete, current list of live DCRE repositories (stage services, orchestrator, platform libraries, infra and tooling) lives in one place: the [DCRE design register README](https://github.com/sean-huni/dcre-design-register/blob/dev/README.md#repositories). Deprecated and archived repositories are deliberately absent from it. This README does not copy that list, so it cannot drift.

- Design register: https://github.com/sean-huni/dcre-design-register (start at `docs/specs/DESIGN-REGISTER.md`; the diagrams in `docs/diagrams/` are the specification)
