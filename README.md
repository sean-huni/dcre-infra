# dcre-infra

Dev infrastructure for DCRE 3.0 (collections, payments and mandates): kind cluster, CockroachDB, the per-client exchange tree, LGTM observability, fleet runbook scripts and the Fintegrate simulator.

## What it does

Provides the two local environments the DCRE fleet runs against: a Docker Compose inner loop and a kind cluster for pipeline DevTesting, both on the same images (dev/prod parity). It also carries the operational runbooks as scripts: 13-step clean-slate reset, fleet release switcher with downgrade guards, port-forward self-healing, and the Fintegrate reply simulator that closes the pain.008 to pain.002-family loop.

The fleet is 28 Spring Batch stage services across three families, plus 2 cross-family services, 5 platform libraries and the Quarkus AGT orchestrator. Verified on disk 2026-08-08, after the v1 cutover work:

```bash
cd ~/env/repo/be/java/spring/dcre
for f in collections payments mandates shared platform; do
  printf "%s: " "$f"
  for d in $f/*/; do [ -f "$d/build.gradle" ] && [ -d "$d/src/main" ] && echo "$d"; done | wc -l
done
# collections: 9   payments: 9   mandates: 10   shared: 2   platform: 5
```

All 28 required services are present, and a count is not what proves it: compare the SET, since a family can hold exactly the right NUMBER of services and be wholly non-conformant. `scripts/verify-topology.sh` does that comparison by name and is the gate:

```bash
./scripts/verify-topology.sh; echo "exit=$?"
#   0 conformant | 1 deviates | 2 the tree could not be read, which is NOT a pass
```

The canonical set is the diagrams' set (design-register R-49):

```
collections/   crr ctv cde crw cir   cix csx cpx   crg     -> dcre_col
payments/      prr ptv pai prw pir   pix psx ppx   prg     -> dcre_pay
mandates/      mrr mrv mas mit mir mrw   mix msx mpx   mrg -> dcre_man
shared/        hcs                                          -> dcre_hcs
shared/        rpt                       (reads only; no database of its own)
platform/      platform-batch -copybook -files -model -persistence
```

**One database per owning context. They are never shared.** `agt_ops` is orchestrator state.

A database is named for the context that OWNS it. The three family databases keep family names because nine or ten services share each; a single-service context takes the SERVICE's name, hence `dcre_hcs` rather than a topic name that would leave the owner unstated.

`hcs` was previously a shared TABLE inside a family database (SCRUM-107, 2026-08-08): `public_holiday` in `dcre_col`. That is two homes for one fact, with nothing at read time to say which is stale. It earns a context of its own because it INGESTS from a real upstream (the Nager.Date API, on a six-hour sync) and has an accountable owner.

### Account reference data is an ARTIFACT, not a service

`account` had the same two-homes problem, twice over: two different tables both named `account`, in `dcre_col` and `dcre_man`, with different shapes and disjoint rows. On 2026-08-08 it was solved the same way as `hcs`, with a shared `acs` service and a `dcre_acs` database. **That was reversed on 2026-08-09 and the service is retired**, because unlike `hcs` it had no authoritative source, no accountable owner, no ingestion of its own and no freshness contract. An external review's phrase for it was "a shared integration database disguised as a bounded context", and it put a runtime dependency on the first validation gate of all three families in exchange for 110 static fixture rows.

The replacement is ONE immutable versioned artifact that each context materialises locally:

```
authoritative source  (unknown today, gated by A-4)
      |
      v
  ONE immutable versioned artifact          fixtures/reference/account/<dataset_version>/
  dataset_version, schema_version, source_id,      manifest.properties
  effective_ts, publication_ts, row_count, checksum   account.csv
      |
      +--> collections loader --> dcre_col account   NOT NULLs KEPT
      +--> payments loader    --> dcre_pay account   NOT NULLs KEPT
      +--> mandates loader    --> dcre_man account   NOT NULLs KEPT
```

`account` therefore exists in three databases, and that is not the two-homes defect: they are three different PROJECTIONS of one artifact, nothing writes them but their own loader, each records the `dataset_version` it consumed, and no context reads another's. The 17-column collections shape and the mandates shape stay DIFFERENT, which is the whole point: the retired union table had to relax every `NOT NULL` of both originals to nullable, because neither writer could satisfy the other's mandatory set, so the database stopped being able to refuse a collections row with no branch code. Each context keeps its own constraints now.

Infra seeds none of it. `scripts/verify-account-reference.sh` VALIDATES the artifact (all seven manifest fields, checksum over the bytes of `account.csv`, header shape, row count, known shapes, uniqueness) and `scripts/test-verify-account-reference.sh` red-proofs that gate by mutation, 14 cases. The maximum-age check is wired into every loader and is deliberately INERT: A-4 owns the number and nothing here invents one.

Four services were renamed on 2026-08-08: `ixr sxr pxr` became `cix csx cpx` and `ais` became the payments service `pai`. **`prg` denoted the COLLECTIONS report generator before that date and the PAYMENTS one after it**; the collections service is now `crg`. See the design register's `docs/specs/2026-08-08-service-name-map.md` at https://github.com/sean-huni/dcre-design-register.

- **Compose (inner loop):** `docker compose up -d` gives CockroachDB (SQL 26257, DB Console 8081) and grafana/otel-lgtm (Grafana 3000, OTLP 4317/4318).
- **kind (pipeline DevTesting):** `./scripts/kind-up.sh` creates cluster `dcre-dev` with the control namespace `dcre` plus the three flow namespaces `dcre-col`, `dcre-pay` and `dcre-man` (`k8s/base/00-namespace.yml`), AGT RBAC in all four, in-cluster CockroachDB and LGTM, and the `dcre-exchange` PVC backed by this repo's `exchange/` dir (drop a file locally, pods see it).

## Architecture and principles

- **SOLID, applied here:** one script per responsibility (`crdb-forward.sh` only forwards, `lgtm-up.sh` only revives the observability stack, `env-reset.sh` only resets); each is standalone and idempotent, and `kind-up.sh` composes them instead of duplicating them. Manifests (`k8s/base`, kustomize), scripts, and fixtures are separate seams.
- **12FactorApp Alignment - https://12factor.net/:** config strictly from the environment (`.env.example` documents the committed working defaults; clean-clone rule: everything runs with NO `.env`, the file is the override point); dev/prod parity (identical `cockroachdb/cockroach:v26.2.3` and `grafana/otel-lgtm:0.29.0` images in compose and kind); backing services as attached resources (DB via JDBC URL, telemetry via `OTEL_EXPORTER_OTLP_ENDPOINT`); stage services are stateless one-shot processes minted as k8s Jobs by AGT.
- **Idempotent restart semantics:** `crdb-init.sql` is guarded (`CREATE DATABASE IF NOT EXISTS`, never DROP); the forward scripts kill-and-restart safely; `env-reset.sh` step ordering is load-bearing (AGT down first, schema-change job drain before any seed).
- **Liquibase owns every schema (version 1, owner directive 2026-08-08):** nothing in this repo pre-creates a Liquibase history table or seeds a changelog. `seed-liquibase-history.sql` did exactly that and has been DELETED, along with the reset step that applied it and the 46-table count that verified it. A v1 schema nobody can prove came from a changeset is not a v1 schema. One item of the same class survives and is flagged rather than hidden, because the table has no owning changelog yet: `seed-man-core.sql` still pre-applies `mandate_reason_code` to `dcre_man`. It is deleted when the mandates changelogs take that table over. Note the consequence of `account`/`account_type` LEAVING `seed-man-core.sql` in SCRUM-107: infra no longer pre-creates them in `dcre_man`, so the concurrent-first-boot race those pre-creates suppressed is unguarded again, and `dcre_man.account` is minted empty by whichever M-service boots first. It is FILLED by MRV's own loader job from the versioned artifact, and running that job is now part of bringing an environment up.
- **Guard rails over convention:** `switch-version.sh` refuses fleet downgrades that would durably poison data (2.0 boundary, 2.0.1 A-45 fix, 2.1.x per-client tree and attempt schema).

## Exchange directory contract (R-30/R-31, per-client SCRUM-42)

Client-first layout under the single exchange root: `exchange/<clientbase>/<channel>/<sub>`, with `clientbase` lowercase for each client in scope (`fnbcc01`, `fnbcc02`, `fnbrf01`). Each channel has its `in`/`out`/`error`/`archive` lifecycle subdirs:

- `onhost-req` (in/error/archive): inbound copybooks; filenames carry client + MsgId; AGT watches `in`.
- `onhost-req-endo` (in/error/archive): inbound ENDO Payments DAG (`PRR -> PTV -> PAI -> { PRW , PIR }`).
- `onhost-resp` (out/error/archive): CIR/CRG output on collections, PIR/PRG on payments.
- `fint-req` (out/error/archive): CRW pain.008 on collections and PRW pain.008 on payments; fint-sim consumes `out`.
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

Five databases, `agt_ops`, `dcre_col`, `dcre_man`, `dcre_pay` and `dcre_hcs`, are created at first bootstrap in both environments, from two files that must be kept in lockstep (both guarded, never DROP): `scripts/crdb-init.sql` under compose, and the `crdb-init` ConfigMap in `k8s/base/02-crdb.yml` under k8s. `dcre_pay` is the payments family's own database (SCRUM-107): before it existed the payments lane ran in the `dcre-pay` namespace while writing `dcre_col`, which is namespace isolation without data isolation. Assert the full roster with `scripts/verify-databases.sh`.

The roster appears in three places and they are checked against each other rather than trusted, since a database added to only one of them exists in only one environment:

```bash
cd /path/to/dcre-infra
grep -oE 'CREATE DATABASE IF NOT EXISTS [a-z_]+' scripts/crdb-init.sql   | awk '{print $NF}' | sort > /tmp/a
grep -oE 'CREATE DATABASE IF NOT EXISTS [a-z_]+' k8s/base/02-crdb.yml    | awk '{print $NF}' | sort > /tmp/b
grep -oE 'EXPECTED="[^"]+"' scripts/verify-databases.sh | sed 's/EXPECTED="//;s/"//' | tr ' ' '\n' | sort > /tmp/c
diff /tmp/a /tmp/b && diff /tmp/a /tmp/c && echo "in lockstep"
```

**Migration note (pre-existing environments):** the initdb path (compose mount, k8s `crdb-init` ConfigMap) runs on FIRST bootstrap only; an environment that already has a CRDB volume or a live cluster does not re-run it. Such environments pick up the later databases via `env-reset.sh` step 4, or manually: `CREATE DATABASE IF NOT EXISTS dcre_man;` / `CREATE DATABASE IF NOT EXISTS dcre_pay;` / `CREATE DATABASE IF NOT EXISTS dcre_hcs;`.

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
| `grafana-dashboards.sh` | Posts two dashboard packs (fixed UIDs, `overwrite:true`, idempotent): `dcre-client-stats` to every org (session-identity portability: one JSON renders per-client via each org's scoped datasource) and `dcre-internal-stats` to FNB Internal only. **This is the HTTP-API path and it is superseded for the fleet's OTLP boards**, which are generated and file-provisioned by `obs-dashboards.py`; the two share nothing and neither extends the other |
| `obs-dashboards.py` | The GENERATOR for the fleet's four OTLP dashboards (Overview, Stage Jobs, Traces, Logs). Emits exactly one artifact, `k8s/base/05-obs-dashboards.yml`, a ConfigMap holding the Grafana dashboard provider and the four dashboard JSONs; `04-lgtm.yml` mounts the provider into Grafana's provisioning directory and the JSONs into `/etc/dcre/dashboards`. Three modes. Default rewrites the artifact. `--check` regenerates in memory and fails on drift, and additionally fails when `04-lgtm.yml` stops projecting a key this generator emits, because the manifest naming each file is a second home for that fact whose failure is otherwise silent. `--verify` runs EVERY panel target against the live Prometheus, Loki and Tempo, refuses to publish on any query error, and lists every target that returned empty. Red-proofed on four arms: a hand-edited artifact, a removed `items` entry, a malformed PromQL expression, and an unreachable Grafana (exit 2, never a clean pass) |
| `obs-alerting.py` | The GENERATOR for the fleet's five alert rules and the Slack contact point, REPLACING the deleted `grafana-alerts.sh` (which drove the provisioning HTTP API, had never been loaded into this cluster, and carried four defects: `absent(` twice over a PUSH fleet, `increase()` over a database-polled gauge, a threshold on `dcre_sla_pending_amber` which does not exist as a metric name, and no contact point at all). Emits two artifacts: `k8s/base/06-obs-alerting.yml`, a ConfigMap holding both provisioning files, and `k8s/overlays/alerting-slack/`, the one-command opt-in that mounts the contact point. Four modes. Default rewrites both artifacts. `--check` fails on drift in either, fails when `04-lgtm.yml` stops mounting the rules, and fails LOUDLY when it starts mounting the contact point in the base. `--verify` runs every rule expression against the live Prometheus and reports each rule as ARMED, QUIET or ERROR. `--defects` prints what was wrong with the script it replaces. Red-proofed on nine arms, two of which found real holes in the gate itself: a substring test passed a renamed env var, and a check was satisfied by a COMMENT in the file under test |
| `obs-provisioning-proof.sh` | The two-part proof that those dashboards came from FILES and not from the API: every dashboard reports `meta.provisioned` true with `provisionedExternalId` naming the mounted file, AND the Grafana log holds zero POSTs to `/api/dashboards/db`. The second half is an absence, so it refuses unless a POST of some OTHER kind is present in the same log through the same matcher: without that control the assertion is equally satisfied by a log that records nothing, which is what this bundle does by default. Exit 2 for an unreachable Grafana, never conflated with a pass |
| `rpt-accuracy-check.sh` | 60-assertion accuracy matrix (19 per-client checks x 3 clients, plus 2 ops checks and 1 cross-client integrity assertion; counted 2026-08-08 from the `check` call sites and the trailing inline assertion): independent raw-SQL derivation from base tables (as `root`) vs the rpt views the dashboards display (as each client / `rpt_internal`); fail-closed (empty/non-numeric FAILS), exits non-zero on any mismatch (spec gate) |
| `rpt-security-probes.sh` | Negative security probes: grants wall (client role denied on `public.*` and ops views, asserting SQLSTATE 42501) plus per-view cross-client scoping and a non-emptiness canary; exits non-zero on any unexpected access |
| `grafana-screenshots.mjs` | Playwright (headless chromium) evidence capture: logs in as each org user and screenshots every dashboard, proving per-client isolation and full panel rendering (tall viewport so lazy panels paint). Manifest: `scripts/package.json` |
| `env-reset.sh [--seed mandates.sql]` | 12-step clean slate: stop AGT, delete Jobs/pods, stop fint-sim, drop+recreate all five DBs (connected to `defaultdb` explicitly), drain CRDB schema-change jobs, apply the `dcre_man` shared core, VERIFY the account reference artifact, clean the exchange, restart AGT, optional mandate-book overlay, warm-up drops per route, post-checks, restart fint-sim. Every `cockroach sql` call names its database with `--database=`, and the helper refuses a call that omits it. **`--seed` takes ONE file now, the mandate book**, which loads into `dcre_col` where the legacy collections `mandate` table lives. The old two-argument form is a hard ERROR naming the replacement, because an accounts file quietly ignored looks exactly like an accounts file applied. Infra seeds no account data at all: step 6 verifies the artifact and each context's own loader materialises it |
| `cutover-v1.sh [--yes-drop-everything] [--audit-only]` | The version 1 direct cutover: drops all five databases and lets each service's Liquibase build v1 from scratch. **Refuses without `--yes-drop-everything`**, and refuses on any cluster that is not the kind dev cluster (three independent checks: context name, the cluster the context points at, and the `dcre-dev-control-plane` node). Prints the exact `DROP DATABASE` list before either guard runs. Afterwards it recreates the five databases, calls `verify-databases.sh`, and runs a per-context isolation audit over TWO universes: service PREFIXES (each database holds its own objects and none of another context's) and exact relation PLACEMENT (`public_holiday` only in `dcre_hcs`; `account` in EACH of `dcre_col`, `dcre_pay` and `dcre_man` because each is that context's own projection; `account_type` in `dcre_man` alone). Placement is a separate universe because the moved relations carry no service prefix, so the prefix audit is structurally blind to them. Every absence carries a positive control, and a failed control reports the INSTRUMENT as broken, which is never conflated with the assertion having failed. Exit codes: `0` isolated, `1` a real violation, `2` unreadable (not a pass), `3` PENDING because no changelog has run yet. `--audit-only` runs the audit and nothing else |
| `test-cutover-placement.sh` | Red-proofs the placement half of that audit against a stub `kubectl`: 12 cases covering a clean cluster, each relation left in the wrong database (including as a VIEW), empty databases reporting PENDING rather than PASS, a sabotaged catalog search reporting INSTRUMENT FAILED rather than an assertion failure, and a violation outranking a concurrent pending. No cluster needed |
| `switch-version.sh <1.MINOR.PATCH>` | Fleet-wide release switch for the **version 1 line only**: sets the AGT image and all 29 `AGT_<STAGE>_IMAGE` envs (9 collections, 9 payments, 10 mandates, plus cross-family `HCS`; `RPT` is not launched as a Job so it takes no image env). Rewritten in bash on 2026-08-08 with the correct roster; it carries a positive control on the roster's own shape and a guard that refuses if any retired name reappears in it. **Refuses every pre-cutover target** (`1.0`, `1.1`, any `2.x`): those lines shipped image names that are no longer built, so pointing AGT at them would wedge every stage on `ImagePullBackOff`, and the databases they wrote no longer exist. Within v1, refuses a downgrade below the running version |
| `fint-sim.sh` + `fint_sim_reply.py` | Fintegrate simulator: per client, polls `fint-req/out` for `*_PAIN008.xml`, replies with `{client}_{msgId}_ISR/SBSR/PBSR.xml` into `fint-resp/in` (atomic tmp+rename; every 4th tx RJCT with Rsn AC04), archives the request. M10 mandates leg (`--mandate`): polls `fint-req-man/out` for the mrw outbound `*_PAIN009/010/011.xml` and replies with a pain.012 `ISR`(ACCP)/`SBSR`(PDNG)/`PBSR` trio into `fint-resp-man/in`; PBSR is ACCP, except every 4th mandate RJCT with a rotating reason (AC01/AC04/MD01/MS03) and every 7th a delayed debtor-auth (PDNG then a second `-AUTH_PBSR.xml` ACCP after `--auth-delay-seconds`). Fault selection is a stable digest of the MndtReqId, so replays are byte-identical |
| `test_fint_sim_reply.py` | Stdlib verification suite for `fint_sim_reply.py` (mandate trio, reason rotation, delayed-auth, replay-idempotency, collections regression): `python3 scripts/test_fint_sim_reply.py` |
| `crdb-init.sql` | Guarded creation of all five databases: `dcre_col`, `agt_ops`, `dcre_man`, `dcre_pay`, `dcre_hcs`. Kept in lockstep with the `crdb-init` ConfigMap in `k8s/base/02-crdb.yml`: that is the k8s bootstrap authority, this is the compose one |
| `verify-databases.sh` | Asserts the full database roster exists. Fails CLOSED and never conflates the two failure modes: exit 1 is "read the listing, a database is genuinely absent", exit 2 is "could not read the listing, nothing was learned" |
| `verify-account-reference.sh [<artifact-dir>]` | Validates ONE account reference artifact the way every loader validates it: all seven manifest fields present, the directory name agreeing with `dataset.version`, a supported `schema.version`, the SHA-256 over the bytes of `account.csv`, the exact 18-column header, `row.count` against the data rows, every row carrying a KNOWN shape, both projections non-empty, and `account_number` unique across the whole artifact. Exit 1 is "read it, it is invalid"; exit 2 is "could not read it, or the instrument is broken, nothing was learned". With more than one version directory present the argument is REQUIRED: guessing which dataset is current is the fail-open this gate exists to stop |
| `test-verify-account-reference.sh` | Red-proofs the gate above by MUTATION, 14 cases, each breaking exactly one property of a COPY of the real artifact and asserting both the exit code and the specific message. Every CSV mutation proves it CHANGED the file first: a mutation that does not land is an INSTRUMENT failure, never a surviving property. That guard was written because the first run reported a false survivor, having aimed a mutation at a line whose shape it had assumed |
| `test-verify-databases.sh` | Red-proofs `verify-databases.sh` against a stub `kubectl`, asserting an exact exit code per branch: `scripts/test-verify-databases.sh` |
| `file-trace-query.sql` | The saved cross-DB file-name killer query (SCRUM-58): resolve ANY boundary filename to client/direction/kind/route + ordered step timeline. Run as `rpt_internal`; substitute `:fname`. See the trace runbook below |
| `audit-file-trace.sh` | Trace-resolution audit gate (SCRUM-58): every exchange file must resolve to >= 1 row from the killer query; exits non-zero listing any untraceable file. Called by the chaos harness as a post-run gate step |

## Local cluster deployment

Stage images are built in each service repo, then loaded into the cluster; AGT (deployment `dcre-agt`, ServiceAccount `dcre-agt` with RBAC to create/watch batch Jobs and read pods/logs/configmaps/secrets) mints them as short-lived k8s Jobs, one per stage execution:

```bash
# In each stage-service repo: build, image, load
./gradlew bootJar && docker build -t dcre-SVC:TAG . && kind load docker-image --name dcre-dev dcre-SVC:TAG
# AGT (Quarkus, Alpine production image per the fleet's Alpine-only standing rule):
./gradlew build && docker build -f src/main/docker/Dockerfile.jvm.prod -t dcre-agt:TAG .

# Back here: switch the whole fleet to a release (never mixed versions)
./scripts/switch-version.sh 1.0.0

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

**Fleet OTLP dashboards are GENERATED and FILE-PROVISIONED.** Four boards live in the `DCRE`
folder of the in-cluster Grafana: `dcre-fleet-overview` (who is reporting, arrivals, outcomes,
SLA), `dcre-stage-jobs` (launch intents, stage failures, Spring Batch), `dcre-traces` (span rate
and latency plus live TraceQL searches) and `dcre-logs` (volume by level and the failure lines
themselves). They are emitted by `scripts/obs-dashboards.py` into the ConfigMap
`k8s/base/05-obs-dashboards.yml` and delivered by Grafana file provisioning, never clicked into
existence, never hand-maintained as JSON, and never posted through `POST /api/dashboards/db`.
Prove it with `scripts/obs-provisioning-proof.sh`.

Delivering the pair is two applies and a rollout, deliberately narrower than `kubectl apply -k
k8s/base` so a dashboard change cannot churn namespaces or CockroachDB:

```bash
python3 scripts/obs-dashboards.py                       # regenerate the artifact
python3 scripts/obs-dashboards.py --check               # artifact and manifest agree
kubectl apply -f k8s/base/05-obs-dashboards.yml         # ConfigMap FIRST: the Deployment mounts it
kubectl apply -f k8s/base/04-lgtm.yml
kubectl -n dcre rollout status deploy/lgtm --timeout=300s
python3 scripts/obs-dashboards.py --verify              # every panel query, against live data
./scripts/obs-provisioning-proof.sh                     # provisioned:true + zero dashboard POSTs
```

**A rollout of `lgtm` discards every metric, log and trace it holds.** Only `/data/grafana` is on
the PVC; `/data/prometheus`, `/data/loki` and `/data/tempo` live in the container's writable layer
(measured in the running pod on 2026-09-11: `/proc/mounts` carries one `/data/grafana` entry, and
those three directories held 1.5M, 400K and 17M). Grafana's own state, orgs, users and
API-created dashboards, survives; the telemetry does not. The orchestrator's gauges are polled
from the database and so return to full value at the next 60s export, but rate panels need two
samples and anything reading a 6h range reads only as far back as the restart. Do not roll `lgtm`
immediately before capturing evidence.

The earlier claim here, that operational dashboards `dcre-pipeline` and `dcre-agt` are managed via
the Grafana API/MCP, is superseded by the boards above and was in any case not true of this
cluster: both UIDs returned 404 and the only org present was Main Org when checked on 2026-09-11,
so the client-stats provisioning below had not been re-run since the cluster was rebuilt.

### Alerting: rules are live, DELIVERY IS NOT PROVEN

Five alert rules are GENERATED by `scripts/obs-alerting.py` and delivered by Grafana file
provisioning into the `DCRE Alerts` folder, exactly as the dashboards are. They are never clicked
into existence and never posted through `POST /api/v1/provisioning/...`.

| UID | Fires on | Source |
|---|---|---|
| `dcre-orchestrator-absent` | `absent_over_time(target_info{job="agt"}[3m])` | the orchestrator stopped exporting |
| `dcre-collector-absent` | `absent_over_time(up{job="otelcol-contrib"}[30s])` | the OTLP collector stopped reporting |
| `dcre-database-unreachable` | `hikaricp_connections_timeout_total` over 15m | the fleet could not get a CockroachDB connection |
| `dcre-stage-batch-job-failed` | `spring_batch_job_milliseconds_count{spring_batch_job_status="FAILED"}` over 15m | stage executions ending FAILED |
| `dcre-sla-breach-red` | `max by (job, client, flow) (dcre_sla_pending_red)` | transactions past the red SLA |

Three properties of this fleet decide what a correct expression looks like, and all three were
measured on kind-dcre-dev on 2026-09-11 rather than assumed.

**Absence is never `absent()`.** This fleet PUSHES over OTLP. A scrape target that disappears gets
a staleness marker; a push exporter that stops gets none, so `absent()` keeps resolving the last
sample for Prometheus's five minute lookback and the alert cannot fire before the evidence of
death has itself expired. Every absence expression here is `absent_over_time` over a window that is
a MULTIPLE of the measured export step: `count_over_time(target_info{job="agt"}[3m])` is 3, a 60s
step, and `count_over_time(up{job="otelcol-contrib"}[30s])` is 30, a 1s step.

**`rate()` and `increase()` are empty by construction over stage metrics.** A stage service is a
Spring Batch job inside a Kubernetes Job: it exports ONCE and the pod exits, so every execution is
a new pod, a new `instance` and therefore a NEW SERIES carrying one sample. Both functions need two
samples on one series. Red-proofed:
`sum by (job) (increase(spring_batch_job_milliseconds_count{spring_batch_job_status="FAILED"}[5m]))`
returned **0 series** while `last_over_time(...[15m])` over the same metric returned **5**
(dcre-mrg 29, dcre-crg 15, dcre-cix 1, dcre-cpx 1, dcre-csx 1). The rules read the cumulative
counter over an explicit window, which also states its universe instead of inheriting Prometheus's
lookback flag. The `X - X offset` form is wrong here too, because the two series being subtracted
would be different pods.

**Every rule keeps its OWN labelset.** There is deliberately no rule that ORs several absence terms
under one static `job` label: N absence terms each return their own `job`, and stamping one over
all of them makes Prometheus refuse the whole rule the moment TWO services are absent, which is
exactly the case such a rule exists for.

#### The contact point is an OPT-IN, and that is a measured decision

`kubectl apply -k k8s/base` provisions **rules only**. The Slack contact point is mounted by a
separate overlay, because putting it in the base was tried and it took the whole of Grafana down:

```
failure to map file dcre-contact-points.yaml: failure parsing contact points: dcre-slack:
failed to validate integration "dcre-slack" of type "slack":
recipient must be specified when using the Slack chat API
```

With `$DCRE_SLACK_WEBHOOK_URL` unset, Grafana expands it to EMPTY, stops treating the integration
as an incoming-webhook sender, falls through to the Slack chat API and demands a recipient. Grafana
does NOT skip a provisioning file it cannot validate: it fails the entire provisioning module and
every module that depends on it, so the HTTP server never starts. Measured cost: six minutes of
`0/1 Ready` with no dashboards, no datasources and no rule evaluation, from one notification target
that could not validate. **An inert contact point is not a safe default, it is an outage**, and a
monitoring stack must not be able to fail closed on its notification configuration.

A PLACEHOLDER URL was also measured, and it works: Grafana came up in 5 seconds. It is still not
offered as a default, because a contact point that validates and points nowhere reports as
CONFIGURED while delivering nothing. Absent is honest; placeholder is not.

Turn it on once a REAL webhook exists, in this order:

```bash
kubectl -n dcre create secret generic dcre-alerting-slack \
  --from-literal=webhook-url="$DCRE_SLACK_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k k8s/overlays/alerting-slack
kubectl -n dcre rollout restart deploy/lgtm
```

Grafana reads provisioning files ONCE at startup, so the restart is what delivers the change.

**Backing it out takes three steps, and the third surprises people.** Grafana PERSISTS a
file-provisioned alerting resource in its own database, so removing the file removes nothing:
measured, after the mount was taken away and the pod restarted, the contact point was still there
with `provenance: file`, pointing at a Secret that no longer existed.

```bash
kubectl apply -k k8s/base && kubectl -n dcre rollout restart deploy/lgtm
curl -u admin:admin -H 'X-Disable-Provenance: true' -X DELETE \
  http://localhost:3001/api/v1/provisioning/policies
curl -u admin:admin -H 'X-Disable-Provenance: true' -X DELETE \
  http://localhost:3001/api/v1/provisioning/contact-points/dcre-slack-webhook
```

The `X-Disable-Provenance` header is required: without it Grafana refuses to delete a resource it
believes a file still owns.

#### What is proven, and what is not

PROVEN on kind-dcre-dev, 2026-09-11: five rules read back from
`GET /api/v1/provisioning/alert-rules` with `provenance: file`, all `health: ok`, and
`dcre-sla-breach-red` in state **firing** with labels `client=FNBRF01 flow=COL job=agt`. The
contact point and the notification policy also provisioned with `provenance: file`, and the webhook
reads back `[REDACTED]` through the API.

**NOT PROVEN: that anybody is ever told.** No real webhook exists, so no message has ever been
delivered and no outage has been rehearsed against this contact point. A contact point that has
never delivered is a configuration, not a capability. The delivery rehearsal that would close this,
an outage timed from fault to pending to firing to the message arriving in the channel, is
`_global/observability.md` section 8 and it remains outstanding.

**Client self-service stats** (M8, SCRUM-50) are provisioned and verified deterministically by the scripts above, in order:

```bash
./scripts/lgtm-forward.sh          # Grafana on :3001
./scripts/crdb-forward.sh          # CRDB SQL on :26258 (probes/accuracy need it)
./scripts/grafana-provision.sh     # 4 orgs + per-role scoped datasources (login devdev)
./scripts/grafana-dashboards.sh    # client + internal dashboard packs
./scripts/rpt-security-probes.sh   # grants wall + cross-client scoping (exit 0 = pass)
./scripts/rpt-accuracy-check.sh    # 60-assertion accuracy matrix (exit 0 = pass)

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

The `--database` is passed explicitly (ops-scripting discipline); the query itself resolves everything through fully-qualified 3-part names, so the connected database is otherwise irrelevant. The result is one ordered set: client, direction, kind, route, state, then the step timeline (`ARRIVED`/`QUARANTINED`/`DUPLICATE_REDELIVERY` and `<STAGE>_INTENDED`/`<STAGE>_<OUTCOME>` from the ops side interleaved with `CRR_INGESTED` -> `CTV_VALIDATED` -> `CIR_RESP_STAGED`/`WRITTEN` -> `CRW_PLANNED`/`CRW_VISIBLE` -> `CIX`/`CSX`/`CPX_REPLY` -> `CRG_REPORTED` -> `RPT_OUTCOME` from the business side; the payments equivalents are `PRR`/`PTV`/`PIR`/`PRW` and `PIX`/`PSX`/`PPX_REPLY` -> `PRG_REPORTED`). `scripts/file-trace-query.sql` was corrected to the post-rename labels on 2026-08-08.

**`error/` and `duplicates/` names:** those on-disk names carry a leading `<uuid>_` claim prefix, and after the quarantine row-id fix the uuid IS the arrival/claim id. The owner tables store the BARE name, so strip the `<uuid>_` prefix before pasting `:fname` (or paste the uuid straight into the `arr` CTE). `audit-file-trace.sh` strips it automatically.

**The audit gate (`audit-file-trace.sh`):** after an e2e / chaos run it enumerates every file under the exchange root, runs the killer query for each, and exits non-zero listing any file that returns zero rows (an untraceable boundary file = a capture-layer hole). It excludes `inflight/`, `*.tmp` and hidden markers (`.gitkeep`, `.reset-stamp`, `.staging-drop`) -- the non-deliverable / partial-write artifacts. The chaos harness invokes it as a post-run gate step:

```bash
scripts/audit-file-trace.sh || { echo "trace-resolution gate failed"; exit 1; }
```

Config is 12-factor (committed defaults target the kind cluster, matching `rpt-security-probes.sh`): `DCRE_EXCHANGE_ROOT` (or first arg), `DCRE_COCKROACH` (connection command prefix), `CRDB_USER` (default `rpt_internal`), `CRDB_DATABASE` (default `dcre_col`). Exit codes: `0` all files resolve, `1` one or more unresolved, `2` config error, `3` query/connection failure (fails closed -- a dead DB never false-passes). Override the connection for the inner loop, e.g. `DCRE_COCKROACH="cockroach sql --insecure --host=localhost:26257"`.

**Honest limitations (no backfill, by design):** pre-feature CIR RESP names and pre-feature duplicate re-deliveries stay as dark as they are today; legacy files of every other class trace immediately from existing owner columns. Dev-only `local-<svc>-<executionId>` seam names of the non-rpt modules are self-describing into batch metadata but are NOT killer-query-resolvable (only rpt's seam names are, via `rpt_run`).

## Related repositories

- Orchestrator: [dcre-agt](https://github.com/sean-huni/dcre-agt)
Every repository below is PRIVATE, so an unauthenticated fetch answers 404 for all of them alike, including the ones that exist. Existence was verified 2026-08-08 with `gh api repos/sean-huni/<name> --jq .visibility` alongside an invented control name that correctly returned Not Found.

- Collections (`dcre_col`): [dcre-crr](https://github.com/sean-huni/dcre-crr), [dcre-ctv](https://github.com/sean-huni/dcre-ctv), [dcre-cde](https://github.com/sean-huni/dcre-cde), [dcre-crw](https://github.com/sean-huni/dcre-crw), [dcre-cir](https://github.com/sean-huni/dcre-cir), [dcre-cix](https://github.com/sean-huni/dcre-cix), [dcre-csx](https://github.com/sean-huni/dcre-csx), [dcre-cpx](https://github.com/sean-huni/dcre-cpx), [dcre-crg](https://github.com/sean-huni/dcre-crg)
- Payments (`dcre_pay`): [dcre-prr](https://github.com/sean-huni/dcre-prr), [dcre-ptv](https://github.com/sean-huni/dcre-ptv), [dcre-pai](https://github.com/sean-huni/dcre-pai), [dcre-prw](https://github.com/sean-huni/dcre-prw), [dcre-pir](https://github.com/sean-huni/dcre-pir), [dcre-pix](https://github.com/sean-huni/dcre-pix), [dcre-psx](https://github.com/sean-huni/dcre-psx), [dcre-ppx](https://github.com/sean-huni/dcre-ppx), [dcre-prg](https://github.com/sean-huni/dcre-prg)
- Mandates (`dcre_man`): [dcre-mrr](https://github.com/sean-huni/dcre-mrr), [dcre-mrv](https://github.com/sean-huni/dcre-mrv), [dcre-mas](https://github.com/sean-huni/dcre-mas), [dcre-mit](https://github.com/sean-huni/dcre-mit), [dcre-mrw](https://github.com/sean-huni/dcre-mrw), [dcre-mir](https://github.com/sean-huni/dcre-mir), [dcre-mix](https://github.com/sean-huni/dcre-mix), [dcre-msx](https://github.com/sean-huni/dcre-msx), [dcre-mpx](https://github.com/sean-huni/dcre-mpx), [dcre-mrg](https://github.com/sean-huni/dcre-mrg)
- Cross-family: [dcre-hcs](https://github.com/sean-huni/dcre-hcs), [dcre-rpt](https://github.com/sean-huni/dcre-rpt)
- Platform libraries: [dcre-platform-model](https://github.com/sean-huni/dcre-platform-model), [dcre-platform-files](https://github.com/sean-huni/dcre-platform-files), [dcre-platform-batch](https://github.com/sean-huni/dcre-platform-batch), [dcre-platform-persistence](https://github.com/sean-huni/dcre-platform-persistence). `platform-copybook` is the fifth library and is local-only: it has no git remote and no GitHub repository as of 2026-08-08.
- Orchestrator, tooling and docs: [dcre-agt](https://github.com/sean-huni/dcre-agt), [dcre-fixture-toolkit](https://github.com/sean-huni/dcre-fixture-toolkit), [dcre-design-register](https://github.com/sean-huni/dcre-design-register)
- **Archived on 2026-08-08 and NOT part of the fleet.** These names are retired and must not appear in any manifest, roster, script or dashboard; they are listed here, and only here, so that an archived repository is traceable rather than mysterious: [dcre-ixr](https://github.com/sean-huni/dcre-ixr), [dcre-sxr](https://github.com/sean-huni/dcre-sxr), [dcre-pxr](https://github.com/sean-huni/dcre-pxr), [dcre-ais](https://github.com/sean-huni/dcre-ais). The mandates-side retirements (`mar`, `msr`, `mis`, `maf`) are equally out of the fleet; `mis` and `maf` were renamed to `mit` and `mas`, `mar` was split into `mix`/`msx`/`mpx`, and `msr` was replaced by the `mrg`-derived views
