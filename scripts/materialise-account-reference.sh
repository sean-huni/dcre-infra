#!/usr/bin/env bash
# Materialises the account reference artifact at DEPLOY TIME: validates it, then
# STAGES it where the three per-context loader jobs can actually read it.
#
# WHY THIS EXISTS. CTV, PTV and MRV each carry a Spring Batch account-reference
# loader. Nothing launched them and nothing put the artifact anywhere a pod could
# see, because the only volume a stage pod has is the dcre-exchange PVC and the
# artifact lived only in git. So `account` was empty in every deployed
# environment and every verdict chain answered FAIL_ACCOUNT_NOT_FOUND: a
# deployment step that never happened, reported for months as a data-quality
# problem.
#
# DEPLOY-TIME MATERIALISATION, AND NOTHING ELSE. There is no cadence in this
# file: no timer, no cron, no interval, no "restage if older than". The freshness
# contract is A-4's to define and A-4 is unresolved, so a refresh rhythm invented
# here would be an unowned production rule wearing the costume of a decision.
# Infra applies the artifact when it deploys. That is the whole claim, and it is
# the same claim scripts/verify-account-reference.sh already makes about
# validity: the gate checks the artifact and says plainly that freshness is not
# checked.
#
# SOURCE and DESTINATION are different things, and the second is not a second
# home for the first:
#
#   fixtures/reference/account/<version>/   THE artifact, in git, immutable. A
#                                           correction is a new version
#                                           directory, never an edit.
#   exchange/reference/account/<version>/   the STAGED copy. Host-backed by this
#                                           repo's ./exchange through the kind
#                                           extraMount, surfaced in a pod as the
#                                           dcre-exchange PVC at /exchange, so
#                                           this path reads as
#                                           /exchange/reference/account/<version>.
#
# `exchange/**` is gitignored, so the staged copy is never committed and git
# stays the one home of the fact. The staged copy is a projection of it that this
# script rebuilds; nothing else writes there and no consumer writes back.
# collections/ctv/src/main/resources/application.yml derives its artifact root
# from ${DCRE_EXCHANGE_ROOT}/reference/account for exactly this reason and names
# this script in its comment.
#
# EXIT CODES, the same three verify-account-reference.sh uses, unchanged, because
# every judgement about the artifact's CONTENT is delegated to it:
#
#   exit 0  the artifact is valid and the staged copy is in place
#   exit 1  the artifact was READ and is invalid: a real finding
#   exit 2  the artifact could not be read, the version could not be resolved,
#           or the copy itself failed. NOTHING WAS LEARNED. Never a pass, and
#           never reported as a fault of the artifact's contents.
#
# BASH, NOT ZSH, DELIBERATELY, for the two reasons this project has paid for:
# `for x in $list` does not word-split in zsh, so a loop over a space-joined
# constant compares everything against one long string and matches nothing; and
# ${PIPESTATUS[0]} expands to the EMPTY STRING in zsh rather than erroring, so an
# ad-hoc status capture reads as success. Nothing here is piped into a truncating
# consumer either: every command whose status matters is run on its own line and
# its status read on the next one.
set -u

INFRA="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# 12FactorApp Alignment (https://12factor.net/): committed defaults that work in
# a fresh clone with no .env at all, overridable from the environment.
SOURCE_ROOT="${DCRE_REFERENCE_SOURCE_ROOT:-$INFRA/fixtures/reference/account}"
EXCHANGE_ROOT="${DCRE_EXCHANGE_HOST_ROOT:-$INFRA/exchange}"
DEST_ROOT="$EXCHANGE_ROOT/reference/account"
GATE="$INFRA/scripts/verify-account-reference.sh"
NS="${DCRE_NS:-dcre}"

usage() {
  echo "usage: $(basename "$0") [--version <v>] [--run-loaders]"
  echo
  echo "  Validates fixtures/reference/account/<v> and stages it into"
  echo "  exchange/reference/account/<v>, which a stage pod sees as"
  echo "  /exchange/reference/account/<v> through the dcre-exchange PVC."
  echo
  echo "  --version <v>   the dataset version directory to materialise. REQUIRED"
  echo "                  when more than one exists: guessing which dataset is"
  echo "                  current is the fail-open this gate exists to stop."
  echo "  --run-loaders   ALSO launch the three per-context loader Jobs in the"
  echo "                  cluster. OFF by default and off in both deployment"
  echo "                  scripts. UNVERIFIED against a cluster, see the banner"
  echo "                  above run_loaders() before enabling it."
  echo
  echo "  exit 0 staged  |  exit 1 artifact invalid  |  exit 2 nothing learned"
}

# ---------------------------------------------------------------------------
# Arguments. An argument this script does not understand is NOT ignored: that is
# the shape a mistyped flag has, and a silently ignored --run-loaders or a
# silently ignored --version is exactly the failure this whole change removes.
# ---------------------------------------------------------------------------
VERSION=""
version_given=0
run_loaders_requested=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version)
      if [ "$#" -lt 2 ]; then
        echo "REFUSED(2): --version needs a dataset version directory name."
        usage
        exit 2
      fi
      VERSION="$2"; version_given=1; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; version_given=1; shift ;;
    --run-loaders) run_loaders_requested=1; shift ;;
    *)
      echo "REFUSED(2): unrecognised argument '$1'."
      echo "            An argument this script does not understand is not"
      echo "            ignored: it is the shape a mistyped flag has."
      usage
      exit 2 ;;
  esac
done

# An EMPTY --version is refused rather than silently falling through to the
# single-directory resolution below. Falling through would mean an operator who
# meant to name a version got whichever one happened to be alone, which is the
# fail-open dressed as a convenience.
if [ "$version_given" -eq 1 ] && [ -z "$VERSION" ]; then
  echo "REFUSED(2): --version was given an empty value. It is not treated as"
  echo "            'no version given': you asked for a specific dataset."
  exit 2
fi

# ---------------------------------------------------------------------------
# Version resolution.
#
# This is verify-account-reference.sh's refusal, copied deliberately rather than
# reinvented: with more than one version directory present there is no implicit
# current member, and a deploy step that picks one is asserting a fact nobody
# stated. A DIFFERENT rule in the two scripts would be worse than either rule,
# because the gate and the thing it gates would disagree about which artifact is
# under discussion.
# ---------------------------------------------------------------------------
if [ -z "$VERSION" ]; then
  if [ ! -d "$SOURCE_ROOT" ]; then
    echo "FAIL(2): artifact root '$SOURCE_ROOT' is not a directory."
    echo "         Nothing was read, so no conclusion is drawn about any artifact."
    exit 2
  fi
  n=0
  for d in "$SOURCE_ROOT"/*/; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    VERSION="$(basename "$d")"
  done
  if [ "$n" -eq 0 ]; then
    echo "FAIL(2): no version directory under '$SOURCE_ROOT'."
    echo "         An empty artifact root is an unbuilt artifact, not an empty"
    echo "         dataset, and nothing may be staged from it."
    exit 2
  fi
  if [ "$n" -gt 1 ]; then
    echo "FAIL(2): $n version directories under '$SOURCE_ROOT'; name the one to"
    echo "         materialise with --version. Staging the wrong one silently"
    echo "         changes what every verdict in three families is judged against."
    usage
    exit 2
  fi
fi

SRC="$SOURCE_ROOT/$VERSION"
DEST="$DEST_ROOT/$VERSION"

echo "artifact:    $SRC"
echo "staging to:  $DEST"
echo "             (a stage pod reads this as /exchange/reference/account/$VERSION)"

# The artifact directory is named in EVERY refusal below. "the artifact is
# missing" without a path is a sentence an operator cannot act on, and this
# script's whole job is to make a missing deployment step legible.
if [ ! -d "$SRC" ]; then
  echo "FAIL(2): the artifact directory '$SRC' does not exist."
  echo "         Nothing was staged. The three loaders would find no artifact,"
  echo "         every account lookup would answer FAIL_ACCOUNT_NOT_FOUND, and"
  echo "         that would read as a data-quality problem rather than as this"
  echo "         missing deploy step."
  exit 2
fi

# ---------------------------------------------------------------------------
# (a) VALIDATE, by delegation. None of the eight checks is reimplemented here:
# two implementations of one rule is two homes for one fact, and the day they
# disagree the deploy step and the gate would be arguing about the same bytes.
# ---------------------------------------------------------------------------
if [ ! -x "$GATE" ]; then
  echo "FAIL(2): the gate '$GATE' is absent or not executable."
  echo "         The artifact was NOT validated, so nothing is concluded about"
  echo "         '$SRC' and nothing is staged."
  exit 2
fi

echo "--- validating '$SRC' with $(basename "$GATE") ---"
gate_rc=0
"$GATE" "$SRC" || gate_rc=$?
echo "--- $(basename "$GATE") exited $gate_rc (that status is the gate's own; no"
echo "    pipeline is involved) ---"

if [ "$gate_rc" -ne 0 ]; then
  echo "REFUSED($gate_rc): the artifact '$SRC' did not validate. NOTHING was staged."
  if [ "$gate_rc" -eq 1 ]; then
    echo "            The artifact was read and is INVALID. Staging it would put"
    echo "            an artifact three Spring Batch jobs will reject onto the"
    echo "            PVC, and each of them would fail later and further away."
  else
    echo "            The artifact could not be READ, or the instrument is broken."
    echo "            Nothing was learned about '$SRC', which is itself a reason"
    echo "            not to stage it."
  fi
  exit "$gate_rc"
fi

# ---------------------------------------------------------------------------
# (b) STAGE.
#
# Idempotence first: an artifact is immutable and its directory name IS its
# version, so a staged copy whose bytes already equal the source is already the
# right answer. Re-validating the DESTINATION rather than inferring its state
# from the source having passed is the point: the loaders read the staged copy,
# so the staged copy is what must be proven loadable.
# ---------------------------------------------------------------------------
already_staged=0
if [ -d "$DEST" ]; then
  echo "--- a staged copy already exists at '$DEST'; validating THAT copy, which"
  echo "    is the one the loaders actually read ---"
  dest_rc=0
  "$GATE" "$DEST" >/dev/null 2>&1 || dest_rc=$?
  if [ "$dest_rc" -eq 0 ] \
     && cmp -s "$SRC/account.csv" "$DEST/account.csv" \
     && cmp -s "$SRC/manifest.properties" "$DEST/manifest.properties"; then
    already_staged=1
  else
    echo "    the staged copy differs from the artifact or did not validate"
    echo "    (gate exited $dest_rc). It is REPLACED, not merged: a stale or"
    echo "    partial copy on the PVC is what the loaders would read."
  fi
fi

if [ "$already_staged" -eq 1 ]; then
  echo "--- staged copy is byte-identical to the artifact and validates; nothing"
  echo "    to do. Re-running this script is a no-op, by design. ---"
else
  # Staged into a temp directory INSIDE the destination parent, so the final
  # move is a same-filesystem rename and a half-copied artifact is never visible
  # at the path a loader reads. The temp name is distinctive: exchange/ holds
  # other sessions' working directories and a generic name would collide.
  STAGING="$DEST_ROOT/.materialise-staging.$$"

  mkdir -p "$DEST_ROOT" || {
    echo "FAIL(2): could not create '$DEST_ROOT'. Nothing was staged."
    exit 2
  }
  rm -rf "$STAGING"
  mkdir -p "$STAGING/$VERSION" || {
    echo "FAIL(2): could not create the staging directory '$STAGING/$VERSION'."
    exit 2
  }

  # The DIRECTORY is the artifact, so it is copied whole rather than by naming
  # the two files this script happens to know about. A file added to a future
  # schema must not be silently dropped in transit.
  cp_rc=0
  cp -R "$SRC"/. "$STAGING/$VERSION"/ || cp_rc=$?
  if [ "$cp_rc" -ne 0 ]; then
    echo "FAIL(2): the copy of '$SRC' exited $cp_rc. Nothing was published to"
    echo "         '$DEST'; the half-copy is discarded."
    rm -rf "$STAGING"
    exit 2
  fi

  # The COPY is validated, not assumed. A checksum recomputed over the bytes
  # that landed is the only thing that distinguishes "the artifact was valid"
  # from "the artifact that reached the PVC is valid", and the second is the
  # claim this script is making.
  echo "--- validating the STAGED COPY (the bytes that landed, not the source) ---"
  staged_rc=0
  "$GATE" "$STAGING/$VERSION" || staged_rc=$?
  echo "--- gate on the staged copy exited $staged_rc ---"
  if [ "$staged_rc" -ne 0 ]; then
    echo "FAIL(2): the artifact validated but the COPY at '$STAGING/$VERSION' did"
    echo "         not (gate exited $staged_rc). The copy is discarded and"
    echo "         '$DEST' is left exactly as it was. This is a transfer fault,"
    echo "         not a finding about '$SRC'."
    rm -rf "$STAGING"
    exit 2
  fi

  # Replace. The previous copy is moved aside first rather than deleted, so a
  # failed rename cannot leave the path empty with nothing to fall back to.
  PREVIOUS="$DEST_ROOT/.materialise-superseded.$$"
  rm -rf "$PREVIOUS"
  if [ -e "$DEST" ]; then
    mv "$DEST" "$PREVIOUS" || {
      echo "FAIL(2): could not move the existing staged copy aside. '$DEST' is"
      echo "         untouched and nothing was published."
      rm -rf "$STAGING"
      exit 2
    }
  fi
  mv_rc=0
  mv "$STAGING/$VERSION" "$DEST" || mv_rc=$?
  if [ "$mv_rc" -ne 0 ]; then
    echo "FAIL(2): publishing '$STAGING/$VERSION' to '$DEST' exited $mv_rc."
    [ -e "$PREVIOUS" ] && mv "$PREVIOUS" "$DEST" 2>/dev/null && \
      echo "         the previous staged copy was restored."
    rm -rf "$STAGING"
    exit 2
  fi
  rm -rf "$PREVIOUS" "$STAGING"
fi

# ---------------------------------------------------------------------------
# The result, stated with the universe it was measured over.
# ---------------------------------------------------------------------------
staged_rows=$(awk 'NR > 1 && NF { n++ } END { print n + 0 }' "$DEST/account.csv" 2>/dev/null)
staged_files=$(ls -1 "$DEST" 2>/dev/null | wc -l | tr -d ' ')
echo "STAGED: $VERSION -> $DEST"
echo "        $staged_files file(s), ${staged_rows:-?} data rows, validated AT the destination."
echo "        A stage pod reads this as /exchange/reference/account/$VERSION."
echo "        This stages the DATA the three loader jobs read. RUNNING those jobs"
echo "        is a separate concern and is NOT done here by default: see"
echo "        run_loaders() below and --run-loaders."

# ---------------------------------------------------------------------------
# ============================ UNVERIFIED =================================
# NOT ONE LINE OF run_loaders() HAS EVER BEEN EXECUTED.
#
# Everything above touches the local filesystem only and is red-proofed by
# scripts/test-materialise-account-reference.sh. Launching the loaders needs a
# cluster, and no cluster was reachable when this was written, so this function
# is gated behind --run-loaders, which BOTH deployment scripts leave off. An
# unverified cluster call must not reach the default path of a cutover or a
# reset: that is how a deploy step nobody ran gets reported as working.
#
# WHAT IT WOULD DO, per context (CTV/dcre-col, PTV/dcre-pay, MRV/dcre-man):
#   1. read that stage's image from the AGT deployment's OWN env
#      (AGT_<STAGE>_IMAGE), so the loader runs the same image the pipeline runs
#      and no tag is invented here
#   2. read that context's database URL from the same deployment's env, trying an
#      explicit candidate list and REFUSING, with the keys it did find printed,
#      when none is present
#   3. apply a one-shot Job in that context's flow namespace, mounting PVC
#      dcre-exchange at /exchange, with spring.batch.job.name pointed at the
#      loader through DCRE_<STAGE>_JOB_NAME, and the artifact root and dataset
#      version set explicitly
#   4. wait for each Job and report per context
#
# ONE THING IT CANNOT FIX FROM HERE, and it is a real finding, recorded rather
# than papered over: only CTV derives its artifact root from the exchange root
# (collections/ctv application.yml). PTV and MRV still default theirs to
# ../../../../../../infra/dcre-infra/fixtures/reference/account, six parent hops
# that resolve on a developer's machine and cannot exist in a pod. This function
# therefore sets DCRE_PTV_ACCOUNT_REFERENCE_ROOT and
# DCRE_MRV_ACCOUNT_REFERENCE_ROOT explicitly. The durable fix is in those two
# repos, not in infra.
#
# It FAILS CLOSED on everything it cannot read, and it names what it looked for,
# because "I could not look" must never be reported as "I looked and there was
# nothing".
# ---------------------------------------------------------------------------
# stage : flow-namespace : job-name : root-env : version-env
LOADER_CONTEXTS="CTV:dcre-col:accountReferenceLoadJob:DCRE_CTV_ACCOUNT_REFERENCE_ROOT:DCRE_CTV_ACCOUNT_DATASET_VERSION
PTV:dcre-pay:ptvAccountReferenceLoadJob:DCRE_PTV_ACCOUNT_REFERENCE_ROOT:DCRE_PTV_ACCOUNT_DATASET_VERSION
MRV:dcre-man:mrvAccountReferenceLoadJob:DCRE_MRV_ACCOUNT_REFERENCE_ROOT:DCRE_MRV_ACCOUNT_DATASET_VERSION"

agt_env_value() {
  local key="$1" out rc
  rc=0
  out=$(kubectl get deploy dcre-agt -n "$NS" \
        -o "jsonpath={.spec.template.spec.containers[0].env[?(@.name=='$key')].value}" \
        2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && return 2
  [ -z "$out" ] && return 1
  printf '%s' "$out"
  return 0
}

agt_env_keys() {
  kubectl get deploy dcre-agt -n "$NS" \
    -o "jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}{'\n'}{end}" 2>/dev/null
}

run_loaders() {
  local stage flow job root_env version_env row
  local image db_url candidate rc failures=0

  echo "=========================================================================="
  echo "RUNNING THE THREE ACCOUNT-REFERENCE LOADERS (--run-loaders)"
  echo "THIS PATH HAS NEVER BEEN EXECUTED AGAINST A CLUSTER. Read the banner"
  echo "above run_loaders() in $(basename "$0") before trusting its output."
  echo "=========================================================================="

  while IFS=: read -r stage flow job root_env version_env; do
    [ -n "$stage" ] || continue
    echo "--- $stage ($flow): job $job ---"

    rc=0
    image=$(agt_env_value "AGT_${stage}_IMAGE") || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$image" ]; then
      echo "    REFUSED: could not read AGT_${stage}_IMAGE from deploy/dcre-agt in"
      echo "             namespace '$NS' (lookup returned $rc). The image is NOT"
      echo "             guessed: a loader on a tag nobody deployed would write"
      echo "             rows from a schema nobody shipped."
      echo "             env keys present on that deployment:"
      agt_env_keys | sed 's/^/               /'
      failures=$((failures + 1))
      continue
    fi

    db_url=""
    for candidate in "AGT_${stage}_DB_URL" "DCRE_${stage}_DB_URL" "AGT_${stage}_DATASOURCE_URL"; do
      rc=0
      db_url=$(agt_env_value "$candidate") || rc=$?
      [ "$rc" -eq 0 ] && [ -n "$db_url" ] && break
      db_url=""
    done
    if [ -z "$db_url" ]; then
      echo "    REFUSED: no database URL found on deploy/dcre-agt for $stage. Looked"
      echo "             for AGT_${stage}_DB_URL, DCRE_${stage}_DB_URL and"
      echo "             AGT_${stage}_DATASOURCE_URL and found none of them."
      echo "             THE KEY NAME IS UNVERIFIED: no cluster was available when"
      echo "             this was written, so this list is a candidate set, not a"
      echo "             fact. The keys actually present are:"
      agt_env_keys | sed 's/^/               /'
      failures=$((failures + 1))
      continue
    fi

    local job_name="dcre-${stage}-account-reference-load"
    job_name="$(printf '%s' "$job_name" | tr '[:upper:]' '[:lower:]')"

    echo "    image:   $image"
    echo "    root:    $root_env=/exchange/reference/account"
    echo "    version: $version_env=$VERSION"
    echo "    the Job manifest that would be applied:"

    local manifest
    manifest=$(cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $flow
  labels:
    app.kubernetes.io/part-of: dcre
    dcre.fnb.co.za/purpose: account-reference-load
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: loader
          image: $image
          env:
            - name: DCRE_${stage}_JOB_NAME
              value: "$job"
            - name: $root_env
              value: "/exchange/reference/account"
            - name: $version_env
              value: "$VERSION"
            - name: DCRE_EXCHANGE_ROOT
              value: "/exchange"
            - name: DCRE_DB_URL
              value: "$db_url"
          volumeMounts:
            - name: exchange
              mountPath: /exchange
      volumes:
        - name: exchange
          persistentVolumeClaim:
            claimName: dcre-exchange
YAML
)
    printf '%s\n' "$manifest" | sed 's/^/      /'

    rc=0
    kubectl delete job "$job_name" -n "$flow" --ignore-not-found >/dev/null 2>&1 || rc=$?
    rc=0
    printf '%s\n' "$manifest" | kubectl apply -f - >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "    FAILED: kubectl apply exited $rc for $stage. That status belongs to"
      echo "            the apply, not to the loader, which never started."
      failures=$((failures + 1))
      continue
    fi

    rc=0
    kubectl wait --for=condition=complete "job/$job_name" -n "$flow" --timeout=300s >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "    FAILED: $stage loader Job did not complete within 300s (kubectl wait"
      echo "            exited $rc). Its logs:"
      kubectl logs "job/$job_name" -n "$flow" --tail=50 2>&1 | sed 's/^/              /'
      failures=$((failures + 1))
      continue
    fi
    echo "    $stage loader completed."
  done <<LOADER_EOF
$LOADER_CONTEXTS
LOADER_EOF

  if [ "$failures" -ne 0 ]; then
    echo "LOADERS: $failures of 3 contexts did not load. The account table in those"
    echo "         contexts is still empty and their verdicts will still answer"
    echo "         FAIL_ACCOUNT_NOT_FOUND."
    return 1
  fi
  echo "LOADERS: all three contexts loaded from $VERSION."
  return 0
}

if [ "$run_loaders_requested" -eq 1 ]; then
  loaders_rc=0
  run_loaders || loaders_rc=$?
  echo "run_loaders exited $loaders_rc (that status is run_loaders' own)"
  exit "$loaders_rc"
fi

exit 0
