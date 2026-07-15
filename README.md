# dcre-infra

Dev infrastructure for DCRE Collections 3.0: kind cluster, CockroachDB, the per-client exchange tree, LGTM observability, fleet runbook scripts and the Fintegrate simulator.

## What it does

Provides the two local environments the DCRE fleet (11 Spring Batch stage services plus the Quarkus AGT orchestrator) runs against: a Docker Compose inner loop and a kind cluster for pipeline DevTesting, both on the same images (dev/prod parity). It also carries the operational runbooks as scripts: 13-step clean-slate reset, fleet release switcher with downgrade guards, port-forward self-healing, and the Fintegrate reply simulator that closes the pain.008 to pain.002-family loop.

- **Compose (inner loop):** `docker compose up -d` gives CockroachDB (SQL 26257, DB Console 8081) and grafana/otel-lgtm (Grafana 3000, OTLP 4317/4318).
- **kind (pipeline DevTesting):** `./scripts/kind-up.sh` creates cluster `dcre-dev` with namespace `dcre`, AGT RBAC, in-cluster CockroachDB and LGTM, and the `dcre-exchange` PVC backed by this repo's `exchange/` dir (drop a file locally, pods see it).

## Architecture and principles

- **SOLID, applied here:** one script per responsibility (`crdb-forward.sh` only forwards, `lgtm-up.sh` only revives the observability stack, `env-reset.sh` only resets); each is standalone and idempotent, and `kind-up.sh` composes them instead of duplicating them. Manifests (`k8s/base`, kustomize), scripts, and fixtures are separate seams.
- **12FactorApp Alignment - https://12factor.net/:** config strictly from the environment (`.env.example` documents the committed working defaults; clean-clone rule: everything runs with NO `.env`, the file is the override point); dev/prod parity (identical `cockroachdb/cockroach:v26.2.3` and `grafana/otel-lgtm:0.29.0` images in compose and kind); backing services as attached resources (DB via JDBC URL, telemetry via `OTEL_EXPORTER_OTLP_ENDPOINT`); stage services are stateless one-shot processes minted as k8s Jobs by AGT.
- **Idempotent restart semantics:** `crdb-init.sql` is guarded (`CREATE DATABASE IF NOT EXISTS`, never DROP); `seed-liquibase-history.sql` is `IF NOT EXISTS` throughout; the forward scripts kill-and-restart safely; `env-reset.sh` step ordering is load-bearing (AGT down first, schema-change job drain before seeding, Liquibase history verified before any service returns).
- **Guard rails over convention:** `switch-version.sh` refuses fleet downgrades that would durably poison data (2.0 boundary, 2.0.1 A-45 fix, 2.1.x per-client tree and attempt schema).

## Exchange directory contract (R-30/R-31, per-client SCRUM-42)

Client-first layout under the single exchange root: `exchange/<clientbase>/<channel>/<sub>`, with `clientbase` lowercase for each client in scope (`fnbcc01`, `fnbcc02`, `fnbrf01`). Each channel has its `in`/`out`/`error`/`archive` lifecycle subdirs:

- `onhost-req` (in/error/archive): inbound copybooks; filenames carry client + MsgId; AGT watches `in`.
- `onhost-req-endo` (in/error/archive): inbound ENDO/AIS DAG.
- `onhost-resp` (out/error/archive): CIR/PRG output.
- `fint-req` (out/error/archive): CRW pain.008; fint-sim consumes `out`.
- `fint-resp` (in/error/archive): pain.002-family; fint-sim drops `in`; AGT watches.

Under the inbound channels (`onhost-req`, `onhost-req-endo`, `fint-resp`), `archive` also hosts AGT's nested `inflight/` and `duplicates/` sinks.

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

Databases `dcre_collections` and `agt_ops` are created by `scripts/crdb-init.sql` (guarded, never DROP) in both environments.

## Configuration

All values have committed working defaults (`.env.example`); copy to `.env` only to override.

| Variable | Default | Purpose |
|---|---|---|
| `DCRE_DB_URL` | `jdbc:postgresql://localhost:26257/dcre_collections?sslmode=disable` | Stage-service JDBC URL |
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
| `env-reset.sh [--seed accounts.sql mandates.sql]` | 13-step clean slate: stop AGT, delete Jobs/pods, stop fint-sim, drop+recreate both DBs, drain CRDB schema-change jobs, pre-seed and verify all 26 Liquibase history+lock tables (24 in `dcre_collections`, 2 `rpt_*` in `agt_ops`), clean the exchange, restart AGT, optional reference reseed, warm-up drops per route, post-checks, restart fint-sim |
| `switch-version.sh <1.0\|1.1\|2.0\|2.0.1\|2.1.0>` | Fleet-wide release switch: sets the AGT image and every `AGT_<STAGE>_IMAGE` env (CRR CTV CIR CDE CRW IXR SXR PXR PRG AIS HCS); refuses 2.x to 1.x, 2.0.1 to 2.0, and any downgrade off 2.1.x |
| `fint-sim.sh` + `fint_sim_reply.py` | Fintegrate simulator: per client, polls `fint-req/out` for `*_PAIN008.xml`, replies with `{client}_{msgId}_ISR/SBSR/PBSR.xml` into `fint-resp/in` (atomic tmp+rename; every 4th tx RJCT with Rsn AC04), archives the request |
| `crdb-init.sql` | Guarded creation of `dcre_collections` and `agt_ops` |
| `seed-liquibase-history.sql` | Pre-creates every module's Liquibase history+lock tables (first-run bootstrap-race guard, idempotent) |

## Local cluster deployment

Stage images are built in each service repo, then loaded into the cluster; AGT (deployment `dcre-agt`, ServiceAccount `dcre-agt` with RBAC to create/watch batch Jobs and read pods/logs/configmaps/secrets) mints them as short-lived k8s Jobs, one per stage execution:

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

Grafana dashboards (`dcre-pipeline` RED baseline, `dcre-agt` arrivals/intents/outcomes) are managed via the Grafana API/MCP, never hand-edited JSON; the in-cluster Grafana is PVC-backed so they survive pod restarts.

## Related repositories

- Orchestrator: [dcre-agt](https://github.com/sean-huni/dcre-agt)
- Stage services: [dcre-crr](https://github.com/sean-huni/dcre-crr), [dcre-ctv](https://github.com/sean-huni/dcre-ctv), [dcre-cde](https://github.com/sean-huni/dcre-cde), [dcre-cir](https://github.com/sean-huni/dcre-cir), [dcre-crw](https://github.com/sean-huni/dcre-crw), [dcre-ixr](https://github.com/sean-huni/dcre-ixr), [dcre-sxr](https://github.com/sean-huni/dcre-sxr), [dcre-pxr](https://github.com/sean-huni/dcre-pxr), [dcre-prg](https://github.com/sean-huni/dcre-prg), [dcre-ais](https://github.com/sean-huni/dcre-ais), [dcre-hcs](https://github.com/sean-huni/dcre-hcs)
- Platform libraries: [dcre-platform-model](https://github.com/sean-huni/dcre-platform-model), [dcre-platform-files](https://github.com/sean-huni/dcre-platform-files), [dcre-platform-batch](https://github.com/sean-huni/dcre-platform-batch), [dcre-platform-persistence](https://github.com/sean-huni/dcre-platform-persistence)
- Tooling and docs: [dcre-fixture-toolkit](https://github.com/sean-huni/dcre-fixture-toolkit), [dcre-design-register](https://github.com/sean-huni/dcre-design-register), [dcre-rpt](https://github.com/sean-huni/dcre-rpt)
