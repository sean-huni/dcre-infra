#!/usr/bin/env bash
# Validates ONE account reference artifact directory, the way every loader validates
# it before applying a row. This is the infra-side gate: if it fails here, three
# Spring Batch jobs are going to fail in production for the same reason, and this
# is the cheap place to find out.
#
#   exit 0  the artifact is present, complete, self-consistent and loadable
#   exit 1  the artifact was READ and is invalid: a real finding
#   exit 2  the artifact could not be read at all, or the instrument is broken.
#           NOTHING WAS LEARNED. This is never reported as a pass and never as a
#           failure of the artifact.
#
# BASH, NOT ZSH, DELIBERATELY, and for two separate reasons this project has paid
# for. `for x in $list` does not word-split in zsh, so a loop over a space-joined
# constant compares everything against one long string and matches nothing
# (verify-topology.sh, 2026-08-08). And `${PIPESTATUS[0]}` expands to an EMPTY
# STRING in zsh rather than erroring, so an ad-hoc status capture silently reads
# as success.
#
# NOTHING HERE IS PIPED INTO A TRUNCATING CONSUMER. `cmd | head` reports head's
# status, and under `pipefail` it reports 141 (SIGPIPE) for a run that succeeded.
# Both directions have produced a wrong conclusion in this project, so every
# command whose status matters is run on its own line and its status read there.
set -u

usage() {
  echo "usage: $(basename "$0") [<artifact-dir>]"
  echo "  default: fixtures/reference/account/<the only version directory>"
  echo "  With more than one version directory present, the argument is REQUIRED:"
  echo "  guessing which dataset is current is the fail-open this gate exists to stop."
}

INFRA="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$INFRA/fixtures/reference/account"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

DIR="${1:-}"
if [ -z "$DIR" ]; then
  [ -d "$ROOT" ] || { echo "FAIL(2): artifact root '$ROOT' is not a directory."; \
                      echo "         Nothing was read, so no conclusion is drawn."; exit 2; }
  # Deliberately NOT "the newest" and NOT "the last one alphabetically". An
  # artifact set with more than one version has no implicit current member, and
  # a gate that picks one is asserting a fact nobody stated.
  n=0
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    DIR="$d"
  done
  if [ "$n" -eq 0 ]; then
    echo "FAIL(2): no version directory under '$ROOT'."
    echo "         An empty artifact root is an unbuilt artifact, not an empty dataset."
    exit 2
  fi
  if [ "$n" -gt 1 ]; then
    echo "FAIL(2): $n version directories under '$ROOT'; name the one to verify."
    usage
    exit 2
  fi
fi
DIR="${DIR%/}"

MANIFEST="$DIR/manifest.properties"
DATA="$DIR/account.csv"

[ -d "$DIR" ]      || { echo "FAIL(2): '$DIR' is not a directory."; exit 2; }
[ -r "$MANIFEST" ] || { echo "FAIL(1): manifest.properties is absent or unreadable in '$DIR'."; \
                        echo "         An artifact without its manifest is not an artifact."; exit 1; }
[ -r "$DATA" ]     || { echo "FAIL(1): account.csv is absent or unreadable in '$DIR'."; exit 1; }

# Read one key. Comments start with '#'. A key that is absent yields the empty
# string, which every caller below treats as a FAILURE and never as a default:
# an empty capture must never read as success.
manifest_value() {
  awk -F= -v k="$1" '
    /^[[:space:]]*#/ { next }
    $1 == k { sub(/^[^=]*=/, "", $0); print; found = 1; exit }
    END { if (!found) exit 3 }
  ' "$MANIFEST"
}

rc=0
fail() { echo "FAIL(1): $1"; rc=1; }

# ---- 1. all seven header fields present and non-empty ----------------------
# Named individually rather than looped over a joined string, so a truncated
# constant cannot make this pass vacuously.
DATASET_VERSION=$(manifest_value dataset.version)
SCHEMA_VERSION=$(manifest_value schema.version)
SOURCE_ID=$(manifest_value source.id)
EFFECTIVE_TS=$(manifest_value effective.ts)
PUBLICATION_TS=$(manifest_value publication.ts)
ROW_COUNT=$(manifest_value row.count)
CHECKSUM=$(manifest_value checksum.sha256)

for pair in "dataset.version=$DATASET_VERSION" "schema.version=$SCHEMA_VERSION" \
            "source.id=$SOURCE_ID" "effective.ts=$EFFECTIVE_TS" \
            "publication.ts=$PUBLICATION_TS" "row.count=$ROW_COUNT" \
            "checksum.sha256=$CHECKSUM"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  [ -n "$val" ] || fail "manifest key '$key' is absent or empty. All seven are mandatory."
done

# ---- 2. the version directory's NAME must equal dataset.version -------------
# Two homes for one fact, and this is the cheap place to catch them disagreeing:
# a directory copied to a new name with the manifest left alone would otherwise
# publish itself under a version it does not carry.
BASENAME="$(basename "$DIR")"
if [ -n "$DATASET_VERSION" ] && [ "$BASENAME" != "$DATASET_VERSION" ]; then
  fail "directory is named '$BASENAME' but manifest declares dataset.version='$DATASET_VERSION'."
fi

# ---- 3. schema.version is the one this gate understands ---------------------
SUPPORTED_SCHEMA=1
if [ -n "$SCHEMA_VERSION" ] && [ "$SCHEMA_VERSION" != "$SUPPORTED_SCHEMA" ]; then
  fail "schema.version is '$SCHEMA_VERSION'; this gate understands '$SUPPORTED_SCHEMA' only."
fi

# ---- 4. checksum over the BYTES of account.csv ------------------------------
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SUM=$(shasum -a 256 "$DATA")
  sum_rc=$?
  ACTUAL_SUM="${ACTUAL_SUM%% *}"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SUM=$(sha256sum "$DATA")
  sum_rc=$?
  ACTUAL_SUM="${ACTUAL_SUM%% *}"
else
  echo "FAIL(2): neither shasum nor sha256sum is available; the checksum was not computed."
  echo "         The instrument is missing, so the artifact is unverified, not invalid."
  exit 2
fi
if [ "$sum_rc" -ne 0 ] || [ -z "$ACTUAL_SUM" ]; then
  echo "FAIL(2): the checksum command exited $sum_rc and produced '${ACTUAL_SUM:-<empty>}'."
  echo "         The instrument failed; nothing is concluded about the artifact."
  exit 2
fi
if [ -n "$CHECKSUM" ] && [ "$ACTUAL_SUM" != "$CHECKSUM" ]; then
  fail "checksum mismatch.
         manifest: $CHECKSUM
         actual:   $ACTUAL_SUM"
fi

# ---- 5. header shape, exactly, in order -------------------------------------
EXPECTED_HEADER='shape,account_number,product_code,status,account_type_code,app_no,acc_type,branch_code,balance,max_credit_limit,cancel_reason,country_id,edr_ind,pre_ind,process_status,status_reason,ucn,client_id'
ACTUAL_HEADER=$(awk 'NR == 1 { sub(/\r$/, ""); print; exit }' "$DATA")
if [ "$ACTUAL_HEADER" != "$EXPECTED_HEADER" ]; then
  fail "account.csv header does not match schema $SUPPORTED_SCHEMA.
         expected: $EXPECTED_HEADER
         actual:   $ACTUAL_HEADER"
fi

# ---- 6. row.count counts DATA rows, header excluded -------------------------
ACTUAL_ROWS=$(awk 'NR > 1 && NF { n++ } END { print n + 0 }' "$DATA")
if [ -n "$ROW_COUNT" ] && [ "$ACTUAL_ROWS" != "$ROW_COUNT" ]; then
  fail "row.count is '$ROW_COUNT' but account.csv holds $ACTUAL_ROWS data rows (header excluded)."
fi

# ---- 7. every row carries a KNOWN shape, and both projections are non-empty --
# A shape this gate does not recognise is a hard failure, never a row quietly
# belonging to nobody: the catch-all arm is the FAILING one.
UNKNOWN=$(awk -F, 'NR > 1 && NF && $1 != "COLLECTIONS" && $1 != "MANDATES" { print NR ":" $1 }' "$DATA")
if [ -n "$UNKNOWN" ]; then
  fail "account.csv carries rows whose shape is neither COLLECTIONS nor MANDATES:
$UNKNOWN"
fi
N_COLLECTIONS=$(awk -F, 'NR > 1 && $1 == "COLLECTIONS" { n++ } END { print n + 0 }' "$DATA")
N_MANDATES=$(awk -F, 'NR > 1 && $1 == "MANDATES" { n++ } END { print n + 0 }' "$DATA")
# Counted so the tally control below stays a check on the INSTRUMENT and does not
# misfire on a genuine finding. Without this term an unrecognised shape, which is
# a real defect the gate has just reported at exit 1, unbalances the sum and gets
# re-reported as "the field splitting is broken", turning a finding into
# "nothing was learned". Caught by the mutation suite on 2026-08-09.
N_UNKNOWN=$(awk -F, 'NR > 1 && NF && $1 != "COLLECTIONS" && $1 != "MANDATES" { n++ } END { print n + 0 }' "$DATA")
[ "$N_COLLECTIONS" -gt 0 ] || fail "no COLLECTIONS rows: the collections and payments loaders would each load zero."
[ "$N_MANDATES" -gt 0 ]    || fail "no MANDATES rows: the mandates loader would load zero."

# ---- 8. account_number is unique across the WHOLE artifact ------------------
# The two shapes are disjoint projections, not two homes for one account. A
# number appearing under both shapes would give two families different truths
# for one account, which is the defect the retired shared database had.
DUPES=$(awk -F, 'NR > 1 && NF { seen[$2]++ } END { for (a in seen) if (seen[a] > 1) print a " x" seen[a] }' "$DATA")
if [ -n "$DUPES" ]; then
  fail "account_number is not unique across the artifact:
$DUPES"
fi

# ---- POSITIVE CONTROL ------------------------------------------------------
# Every absence asserted above was found by SEARCHING, and a search proves
# nothing until something proves it can find. These two must hold on any
# artifact this gate would pass, so if they fail the INSTRUMENT is broken and
# no absence above may be believed.
CONTROL_ROWS=$(awk 'END { print NR }' "$DATA")
if [ "$CONTROL_ROWS" -lt 2 ]; then
  echo "FAIL(2): control failed. account.csv has $CONTROL_ROWS line(s) in total, so"
  echo "         the reader is not reading the file and no finding above is trustworthy."
  exit 2
fi
if [ "$((N_COLLECTIONS + N_MANDATES + N_UNKNOWN))" -ne "$ACTUAL_ROWS" ]; then
  echo "FAIL(2): control failed. shape tallies ($N_COLLECTIONS + $N_MANDATES + $N_UNKNOWN)"
  echo "         do not sum to the row count ($ACTUAL_ROWS), so the field splitting is wrong"
  echo "         and every per-shape finding above is measuring something other than what"
  echo "         it names. Every row must land in exactly one of the three tallies."
  exit 2
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: $BASENAME  schema=$SCHEMA_VERSION  rows=$ACTUAL_ROWS (COLLECTIONS=$N_COLLECTIONS, MANDATES=$N_MANDATES)"
  echo "      checksum verified over the bytes of account.csv: $ACTUAL_SUM"
  echo "      source.id=$SOURCE_ID"
  echo "      effective.ts=$EFFECTIVE_TS  publication.ts=$PUBLICATION_TS"
  echo "      Freshness is NOT checked here and no maximum age exists yet (A-4). Every"
  echo "      loader carries the check wired and INERT; none of them invents a number."
else
  echo "FAIL: '$DIR' is not a loadable artifact. The three loaders will refuse it, by design."
fi
exit "$rc"
