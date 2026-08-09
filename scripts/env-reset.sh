#!/bin/zsh
# DCRE full environment reset (clean slate for a fresh test round).
# Distilled from the 2026-07-13 chaos-cycle teardown; hardened 2026-07-14 after the
# per-client live failures (flat warm-up paths, CRDB drop-job race behind the
# "relation ..._databasechangelog already exists" class, stale fint-sim).
# Ordering is load-bearing, see the numbered comments. Invoked by /dcre-reset.
#
# Usage:
#   env-reset.sh                     # reset infra + schema warm-up, no seed overlay
#   env-reset.sh --seed <mandates.sql>   # also overlay the collections mandate book
#
# --seed TAKES ONE FILE NOW, AND IT IS THE MANDATE BOOK. It used to take an
# ACCOUNTS file first, and there is no longer anywhere for that file to go:
# account reference data is not seeded by infra at all. It travels as ONE
# immutable versioned artifact (fixtures/reference/account/) and each of the
# three contexts materialises its OWN projection into its OWN database by
# running its own loader job. Step 6 VERIFIES that artifact and STAGES it into
# the exchange root, where the dcre-exchange PVC makes it visible to a pod as
# /exchange/reference/account/<version>. Step 6 does NOT run the loader jobs.
#
# The two-argument form is not accepted silently. Passing it is an ERROR that
# names the replacement, because an accounts file quietly ignored would look
# exactly like an accounts file applied, and every consequence of that shows up
# later as FAIL_ACCOUNT_NOT_FOUND verdicts with no explanation attached.
#
# NEVER deletes the crdb PVC (data-crdb-0) or the crdb pod's statefulset.
set -euo pipefail
NS=dcre
INFRA=${0:a:h:h}
EX=$INFRA/exchange
CLIENTS=(fnbcc01 fnbcc02 fnbrf01)

SEED_MANDATES=""
if [[ "${1:-}" == "--seed" ]]; then
  if [[ -n "${3:-}" ]]; then
    echo "ERROR: --seed takes ONE file now, the collections mandate book." >&2
    echo "       You passed two, which is the old '<accounts.sql> <mandates.sql>' form." >&2
    echo "       There is no account seed any more and nothing here would have applied" >&2
    echo "       your first file. Account reference data is an immutable versioned" >&2
    echo "       artifact under fixtures/reference/account/, materialised into each" >&2
    echo "       context's own database by that context's own loader job." >&2
    echo "       Re-run as: env-reset.sh --seed ${3}" >&2
    exit 2
  fi
  SEED_MANDATES=${2:?--seed needs the mandate book file}
fi

# single-value SQL helper: sqlval <sql> <db>
#
# The database is MANDATORY and EXPLICIT. It used to be optional, and the two
# callers that omitted it ran against whatever cockroach defaulted to. That is
# the exact shape of the incident this project keeps re-learning: an earlier
# env-reset let the connection database default and put 22 Liquibase history
# tables into defaultdb while its verify step correctly found zero. A caller
# that forgets is now a hard error, never a guess.
#
# Deliberately NOT a pipeline. The old body ended `| tail -1 | tr -d ...`, so
# `x=$(sqlval ...) || x=""` captured TR's status, and tr succeeds on anything:
# the `|| x=""` degradation could never fire, and a failed query was
# indistinguishable from a successful empty one. The last line is taken
# in-process instead, where no exit status can be lost.
sqlval() {
  local sql=$1 db=${2:-} raw rc
  if [[ -z $db ]]; then
    print -u2 -- "BUG: sqlval called without an explicit database. SQL: ${sql%%$'\n'*}"
    return 2
  fi
  raw=$(kubectl exec -n $NS crdb-0 -- cockroach sql --insecure \
        --database=$db --format=tsv -e "$sql" 2>/dev/null)
  rc=$?
  (( rc == 0 )) || return $rc
  # A zero-row result is the HEADER ALONE, with no newline after command
  # substitution strips it. Taking "the last line" of that returns the header
  # text as if it were a value, so `count` reads back as a non-empty, non-zero
  # answer. Zero rows is not a value: say so and let the caller degrade.
  [[ $raw == *$'\n'* ]] || return 3
  raw=${raw##*$'\n'}
  print -r -- ${raw//[[:space:]]/}
}

echo "[1/12] stop AGT first (watcher/reconciler/clocks must not write to a dropped DB)"
kubectl scale deploy dcre-agt -n $NS --replicas=0
kubectl wait --for=delete pod -l app=dcre-agt -n $NS --timeout=90s 2>/dev/null || true

echo "[2/12] delete all Jobs and stage pods across control + flow namespaces"
echo "       (SCRUM-70: stage Jobs live in dcre-col/dcre-pay/dcre-man; crdb-0 in"
echo "       $NS is NOT dcre-* prefixed: kept)"
for ns in dcre dcre-col dcre-pay dcre-man; do
  if [[ $ns == "$NS" ]]; then
    kubectl delete jobs -n $ns --all --wait=false
    kubectl get pods -n $ns --no-headers | awk '$1 ~ /^dcre-/ {print $1}' \
      | xargs -r kubectl delete pod -n $ns --wait=false --grace-period=0
  else
    # Flow namespaces hold nothing but stage Jobs/pods; tolerate a cluster
    # that predates the SCRUM-70 kustomize apply (namespace absent).
    kubectl delete jobs -n $ns --all --wait=false 2>/dev/null || true
    kubectl delete pods -n $ns --all --wait=false --grace-period=0 2>/dev/null || true
  fi
done

echo "[3/12] stop fint-sim (a stale pre-restructure sim survives resets and keeps"
echo "       writing the old flat paths; a fresh one restarts in step 12)"
pkill -f fint-sim 2>/dev/null || true

echo "[4/12] drop + recreate all five databases"
# SCRUM-107: dcre_pay joined the reset, and so did dcre_hcs. A database that
# escapes the reset is worse than one that is missing: the other databases come
# back empty while its stale rows survive, so a "clean slate" run is quietly not
# clean. That is especially true of a reference database, whose whole job is to
# be the single home of a fact.
#
# dcre_acs was here for one day and is deliberately gone (2026-08-09). Its
# service was retired for having no authoritative source, no accountable owner,
# no ingestion of its own and no freshness contract. Do not add it back: the
# account rows now live in each context's OWN database and are dropped and
# rebuilt with it, by that context's loader, from the versioned artifact.
# --database=defaultdb is EXPLICIT and load-bearing: defaultdb is the one database
# not being dropped, and a defaulted connection database is how 22 Liquibase
# history tables once landed somewhere nobody was looking while the verify step
# correctly found zero.
kubectl exec -n $NS crdb-0 -- cockroach sql --insecure --database=defaultdb -e "
  DROP DATABASE IF EXISTS dcre_col CASCADE;
  DROP DATABASE IF EXISTS agt_ops CASCADE;
  DROP DATABASE IF EXISTS dcre_man CASCADE;
  DROP DATABASE IF EXISTS dcre_pay CASCADE;
  DROP DATABASE IF EXISTS dcre_hcs CASCADE;
  CREATE DATABASE dcre_col;
  CREATE DATABASE agt_ops;
  CREATE DATABASE dcre_man;
  CREATE DATABASE dcre_pay;
  CREATE DATABASE dcre_hcs;"

echo "[5/12] drain async schema-change jobs (DROP ... CASCADE returns while its jobs"
echo "       still run: 'NOTICE: waiting for job(s) to complete'; seeding or scaling"
echo "       into that window collides with half-materialized metadata)"
# SCHEMA CHANGE GC excluded: it only reclaims data ranges later and can linger.
typeset -i drain=0
while :; do
  # defaultdb EXPLICITLY: SHOW JOBS is cluster-scoped and would answer the same
  # from anywhere, but this script has no defaulted-database exemption for
  # "harmless" reads, and defaultdb is the one database not being dropped.
  pending=$(sqlval "SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE','NEW SCHEMA CHANGE') AND status IN ('pending','running');" defaultdb) || pending=""
  [[ "$pending" == "0" ]] && break
  drain+=1
  if (( drain > 24 )); then
    echo "WARN: schema-change jobs still not drained after 120s (pending=${pending:-?}); continuing" >&2
    break
  fi
  sleep 5
done

echo "[6/12] apply the CANONICAL shared reference data:"
echo "       - dcre_man: seed-man-core.sql (mandate_reason_code)"
echo "       - accounts: NOT SEEDED INTO A DATABASE HERE. The artifact is verified"
echo "         and STAGED into the exchange root; the three loaders materialise"
echo "         it from there into their own databases when they run."
# SCRUM-107 v1 cutover: seed-liquibase-history.sql is DELETED and no longer applied
# here. It pre-created every module's Liquibase history+lock tables so a fresh
# database already had them, which is precisely the "hacking around the liquibase
# scripts" the owner ruled out on 2026-08-08. On version 1 there is no history to
# seed: every table is minted by a changeset that actually ran, or it does not
# exist.
#
# WHAT THAT GIVES BACK, stated plainly rather than dropped quietly: the file
# existed to stop concurrent FIRST runs of the SAME service racing on
# CREATE TABLE <svc>_databasechangelog, because the lock table does not exist yet
# and so nothing serialises the bootstrap. The loser crashes with
# "relation already exists" (M7 straight-cycle e2e, 2026-07-13). That race is now
# unguarded here. The correct home for the fix is each service's own changelog
# (Liquibase's own lock, or a first-run warm-up that runs each stage once
# serially before parallel traffic), NOT infra pre-creating the table. See the
# cutover report; this is an owner decision, not one to paper over here.
#
# OPEN, SAME CLASS: seed-man-core.sql below still pre-applies mandate_reason_code,
# which the mandates services' MARK_RAN 000 bootstraps then skip. It is left in
# place because removing it needs the owning changelogs in the mandates repos to
# take the table over, which is a change in those repos, not in infra.
kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_man \
  < $INFRA/scripts/seed-man-core.sql > /dev/null
typeset -i cguard=0
while :; do
  # SCRUM-107: account and account_type LEFT this core, so the mandates shared
  # core is ONE table, not three. Counting the two departed tables here would
  # make the guard pass only if the split had failed. They are minted by the
  # mandates changelogs now, and account is FILLED by MRV's loader job from the
  # versioned artifact, not by anything in this repo.
  mct=$(sqlval "SELECT count(*) FROM [SHOW TABLES FROM dcre_man] WHERE table_name IN ('mandate_reason_code');" dcre_man) || mct=""
  [[ "$mct" == "1" ]] && break
  cguard+=1
  if (( cguard > 6 )); then
    echo "ERROR: expected 1 dcre_man shared-core table (mandate_reason_code), found ${mct:-0}." >&2
    echo "       NOT scaling AGT up: an M-service bootstrapping now would race the shared-core mint." >&2
    exit 1
  fi
  sleep 5
done
echo "       dcre_man shared-core: mandate_reason_code present"

# ACCOUNT REFERENCE DATA IS NOT SEEDED BY INFRA. It was, for one day, into a
# shared dcre_acs database owned by a service that had no authoritative source,
# no accountable owner, no ingestion of its own and no freshness contract. That
# service is retired. There is exactly ONE immutable versioned artifact, and
# each context materialises its OWN projection into its OWN database, keeping
# its OWN NOT NULL constraints instead of relaxing them to a nullable union.
#
# What this step does instead is REFUSE TO PROCEED with an artifact the loaders
# would reject. Finding a bad checksum here costs a second; finding it in three
# Spring Batch jobs costs a test round. The gate fails closed and never conflates
# "invalid" (exit 1) with "could not be read" (exit 2).
"$INFRA/scripts/verify-account-reference.sh"
echo "       account reference artifact verified."

# AND NOW IT IS ACTUALLY PUT SOMEWHERE A POD CAN REACH IT. Verifying and then
# applying nothing is what this step did until 2026-08-09, and it is the whole
# defect: the artifact lived only in git, the ONLY volume a stage pod has is the
# dcre-exchange PVC, so the three loaders could never have found it. `account`
# was empty in every deployed environment and every verdict chain answered
# FAIL_ACCOUNT_NOT_FOUND, which read as a data-quality problem rather than as a
# deploy step nobody had written.
#
# WHAT THIS STAGES, AND WHAT IT DOES NOT RUN. It copies the artifact into
# exchange/reference/account/<version>, which is the DATA the three loader jobs
# read (CTV accountReferenceLoadJob, PTV ptvAccountReferenceLoadJob, MRV
# mrvAccountReferenceLoadJob). RUNNING those jobs is a SEPARATE CONCERN and is
# deliberately not done here: --run-loaders is NOT passed, because that path has
# never been executed against a cluster and an unverified cluster call must not
# reach a reset's default path.
#
# BEFORE the warm-up in step 10 and before AGT comes back in step 8, so no family
# pipeline can run against a missing artifact. `set -e` is in force and this call
# is not in a condition, so a non-zero exit stops the reset here, which is the
# intended direction: an artifact the loaders would reject is cheaper to find in
# a second than in three Spring Batch jobs.
#
# Step 7 cleans the exchange PER-CLIENT trees and outcomes/ only, so it does not
# remove what this just staged. Do not widen that cleanup to the whole exchange
# root without moving this call after it.
"$INFRA/scripts/materialise-account-reference.sh"
echo "       account reference artifact staged into exchange/reference/account;"
echo "       a stage pod reads it as /exchange/reference/account/<version>."
echo "       Materialisation INTO each database is still each context's own loader"
echo "       job, into dcre_col, dcre_pay and dcre_man respectively, and nothing"
echo "       here launches those jobs."

# The 46-history-table verification that stood here is GONE with the seed it
# verified. It asserted that dcre_col held 24, dcre_man 20 and agt_ops 2 Liquibase
# history+lock tables BEFORE any service returned. Nothing pre-creates those
# tables on version 1, so the assertion could only ever have failed, and an
# assertion that cannot pass is not a stricter gate, it is a broken reset.
#
# It is NOT replaced by a weaker version of itself. The property it was really
# guarding (each family database holds its own objects and no other family's) is
# now asserted AFTER the services have run, by scripts/cutover-v1.sh --audit-only,
# where the tables actually exist and where a foreign-family table is a finding
# rather than a race.

echo "[7/12] clean exchange dirs, per-client tree (find -delete: zsh glob rm aborts on"
echo "       empty dirs; tracked .gitkeep files are kept)"
for base in $CLIENTS; do
  find $EX/$base -type f ! -name '.gitkeep' -delete 2>/dev/null || true
done
find $EX/outcomes -type f ! -name '.gitkeep' -delete 2>/dev/null || true
rm -f $EX/.reset-stamp

echo "[8/12] restart AGT (applies its Liquibase, watcher+clocks resume)"
kubectl scale deploy dcre-agt -n $NS --replicas=1
kubectl rollout status deploy/dcre-agt -n $NS --timeout=120s

echo "[9/12] OPTIONAL mandate-book overlay, BEFORE warm-up:"
echo "        - mandates SQL -> dcre_col   (the LEGACY collections mandate table)"
echo "        There is no accounts half any more. An accounts overlay would be a"
echo "        second home for a fact the versioned artifact already owns, which is"
echo "        the exact shape this wave removed."
if [[ -n "$SEED_MANDATES" ]]; then
  [[ -f $SEED_MANDATES ]] || { echo "ERROR: seed file not found: $SEED_MANDATES" >&2; exit 1; }
  echo "        seeding mandates into dcre_col from $SEED_MANDATES ($(wc -l < $SEED_MANDATES | tr -d ' ') lines)..."
  kubectl exec -i -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_col < $SEED_MANDATES > /dev/null
  echo "        mandates file done: $(sqlval 'SELECT count(*) FROM mandate;' dcre_col) rows in dcre_col.mandate"
else
  echo "        skipped (no --seed): the collections mandate book is absent."
fi

echo "[10/12] warm-up drops: one tiny file per route so every service's Liquibase"
echo "        recreates its tables (files NACK against a fresh seed: expected, harmless)"
WARM_REQ_IN=$EX/fnbrf01/onhost-req/in
WARM_ENDO_IN=$EX/fnbrf01/onhost-req-endo/in
for d in $WARM_REQ_IN $WARM_ENDO_IN; do
  if [[ ! -d $d ]]; then
    echo "ERROR: warm-up target $d missing." >&2
    echo "       Fixtures are FNBRF01_*; per-client layout (SCRUM-42) is exchange/<clientbase>/<route>/in/." >&2
    echo "       Restore the per-client exchange tree (git checkout dcre-infra exchange/) and re-run." >&2
    exit 1
  fi
done
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120010002.txt $WARM_REQ_IN/
cp $INFRA/fixtures/warmup/FNBRF01_DCRERF2026071120020002.txt $WARM_ENDO_IN/
# Account reference data is NOT checked here, and its absence at this point is
# EXPECTED rather than a fault: each context's table is materialised by that
# context's own loader job, which has not run yet on a database this script only
# just recreated. Only the OPTIONAL collections mandate book, which --seed alone
# creates, is in doubt at this point.
if [[ -n "$SEED_MANDATES" ]]; then
  echo "        verifying dcre_col.mandate exists (created by the --seed DDL in step 9)..."
  typeset -i guard=0
  until kubectl exec -n $NS crdb-0 -- cockroach sql --insecure --database=dcre_col \
        -e "SELECT 1 FROM mandate LIMIT 1;" >/dev/null 2>&1; do
    sleep 10; guard+=1
    (( guard > 60 )) && { echo "ERROR: dcre_col.mandate missing after 10min despite --seed" >&2; exit 1; }
  done
else
  echo "WARN: no --seed given; the LEGACY collections table dcre_col.mandate does" >&2
  echo "      not exist. Nothing in version control mints it, so --seed is the" >&2
  echo "      only path that creates it." >&2
  echo "      Account reference data is a separate matter and is not affected:" >&2
  echo "      step 6 verified the artifact, and each context's loader job fills" >&2
  echo "      that context's own table when it runs." >&2
fi

echo "[11/12] post-checks + reset stamp"
typeset -i hguard=0
ph=""
while :; do
  # SCRUM-107: public_holiday lives in dcre_hcs, the holiday context's own
  # database. Querying dcre_col here would now fail for the right reason and be
  # read as the wrong one: "HCS has not re-synced yet" rather than "this script
  # is looking in a database that no longer holds the table".
  ph=$(sqlval "SELECT count(*) FROM public_holiday;" dcre_hcs) || ph=""
  [[ -n "$ph" && "$ph" != "0" ]] && break
  hguard+=1
  (( hguard > 12 )) && break
  sleep 5
done
if [[ -z "$ph" || "$ph" == "0" ]]; then
  echo "WARN: dcre_hcs.public_holiday is EMPTY (HCS re-sync expected ~10s after AGT up); CDE fail-closes without it" >&2
else
  echo "        dcre_hcs.public_holiday: $ph rows (HCS re-synced)"
fi
so=$(sqlval "SELECT count(*) FROM stage_outcome;" dcre_col) || so=""
echo "        stage_outcome baseline: ${so:-n/a} rows. Transient CRW TECH_FAILED clock"
echo "        windows between AGT-up and the first CDE run (minting cde_schedule) are"
echo "        EXPECTED; subtract this baseline in later pass-rate accounting."
# Reference-data census.
#   dcre_col.mandate  the LEGACY collections mandate table (kept until M11), NOT
#                     the dcre_man projection SCRUM-91 dropped, and NOT account
#                     reference data. Do not "fix" this to point at dcre_man.
#
# THERE IS NO ACCOUNT CENSUS HERE ANY MORE, and its absence is the point. This
# script used to count dcre_acs.account and report it as proof the fleet had its
# reference data. It cannot report that now and must not pretend to: three
# separate tables in three separate databases hold three separate projections,
# each filled by its own loader job, and none of those jobs has run at this
# point in a reset. A count taken here would be zero, correctly, and would read
# as a fault. Ask each context after its loader has run.
#
# Degrades to a WARN instead of aborting the reset. dcre_col.mandate does not
# exist without --seed, and step 10 already prints that warning itself, so a bare
# query here made the script fail on the very condition it had just predicted. A
# post-CHECK must never be the thing that kills the reset.
mndt=$(sqlval "SELECT count(*) FROM mandate;" dcre_col) || mndt=""
if [[ -z "$mndt" ]]; then
  echo "WARN: dcre_col.mandate absent; it is minted ONLY by --seed. CTV mandate" >&2
  echo "      gating stays fail-closed until then." >&2
else
  echo "        legacy collections mandates: $mndt rows in dcre_col"
fi
date +%s > $EX/.reset-stamp
echo "        reset stamp written: $EX/.reset-stamp ($(cat $EX/.reset-stamp))"

echo "[12/12] restart fint-sim (nohup, background; consumes per-client fint-req/out)"
nohup $INFRA/scripts/fint-sim.sh > /tmp/fint-sim.log 2>&1 &
disown
echo "        fint-sim pid $!, log /tmp/fint-sim.log"

echo "env-reset complete: fleet untouched, DBs fresh, exchange clean, fint-sim fresh"
