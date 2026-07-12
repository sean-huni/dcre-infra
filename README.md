# dcre-infra

Dev infrastructure for DCRE Collections 3.0. Two paths, same images (dev/prod parity):

- **Compose (inner loop):** `docker compose up -d` gives CockroachDB (26257, UI 8081), grafana/otel-lgtm (Grafana 3000, OTLP 4317/4318) and the MFT-sim `exchange/` directories.
- **kind (pipeline DevTesting):** `./scripts/kind-up.sh` creates cluster `dcre-dev` with namespace `dcre`, AGT RBAC, in-cluster CockroachDB and the `dcre-exchange` PVC backed by this repo's `exchange/` dir (drop a file locally, pods see it).

## Exchange directory contract (R-30/R-31)

`onhost-req` (inbound copybooks; filenames carry client + MsgId) · `onhost-resp` (CIR/PRG output) · `fint-req` (CRW pain.008) · `fint-resp` (pain.002-family) · `archive` / `error` (file lifecycle) · `outcomes` (M1/M2 synthetic AGT-service outcome seam, SYNTHETIC-CONTRACT) · `chaos` (test fault injection).

## Env contract

See `.env.example`. Clean-clone rule: everything runs with NO `.env`; the file is the override point. 12FactorApp Alignment - https://12factor.net/.

Databases `dcre_collections` and `agt_ops` are created by `scripts/crdb-init.sql` (guarded, never DROP).

## Dashboards

Grafana (LGTM, http://localhost:3000): `dcre-pipeline` (RED baseline: stage runs/failures/p95/records by service) and `dcre-agt` (arrivals, intents, outcomes, lease, reconciler orphans). Managed via API/MCP, never hand-edited JSON; series bind in M1/M2 when services emit `dcre_*` / `agt_*` metrics.
