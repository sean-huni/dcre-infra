#!/usr/bin/env bash
# Switch the whole DCRE fleet to a release of the VERSION 1 line.
#
# BASH, NOT ZSH, DELIBERATELY (converted 2026-08-08 with the v1 cutover). The
# previous zsh version iterated a zsh array, which was correct, but the file also
# carried `${${CURRENT#*.}%%.*}` and `${(L)s}`, both zsh-only, so a future edit
# that reached for a plain `for s in $LIST` would silently stop word-splitting and
# export ONE env var named after the whole string. Same class of failure that
# verify-topology.sh carries its shebang for.
#
# WHAT CHANGED ON 2026-08-08 (owner directive, direct cutover):
#   "Drop all the DBs & perform a direct cut-over. Fix the Liquibase scripts.
#    Previously it was execution on the wrong designs, now that is executing on
#    the correct design. From now onwards it's version 1."
#
# So this script serves the version 1 line ONLY, and the roster it exports is the
# diagrams' roster: 28 stage services across three families plus the cross-family
# HCS. The pre-cutover names (IXR SXR PXR AIS, and MAR MSR MIS MAF before them)
# are retired: their repositories are archived and their images are not built, so
# exporting AGT_IXR_IMAGE=dcre-ixr:<v> would name an image that cannot exist and
# wedge the launch. They therefore appear nowhere in this file.
#
# PRG IS THE PAYMENTS REPORT GENERATOR. Before 2026-08-08 the same token named
# the COLLECTIONS one, which is now CRG. A find-and-replace on this token produces
# a file that parses and is semantically inverted; read every occurrence in context.
set -euo pipefail

VERSION=${1:-}
case "$VERSION" in
  1.*.*)
    # The v1 line. Digits-only 3-component SemVer per the global tag standard.
    ;;
  1.0|1.1|2.*)
    echo "REFUSED: '$VERSION' is a PRE-CUTOVER release line." >&2
    echo "The 2026-08-08 cutover retired the image names those lines shipped" >&2
    echo "(dcre-ixr, dcre-sxr, dcre-pxr, dcre-ais, and the collections dcre-prg)." >&2
    echo "Pointing AGT at them would set every AGT_<STAGE>_IMAGE to an image that" >&2
    echo "is no longer built, and each stage Job would wedge on ImagePullBackOff." >&2
    echo "There is also nothing left to roll back TO: the v1 cutover dropped and" >&2
    echo "rebuilt every database, so no 2.x ledger rows survive." >&2
    exit 65
    ;;
  *)
    echo "usage: $0 <1.MINOR.PATCH>    e.g. $0 1.0.0" >&2
    echo "Version 1 line only; digits-only 3-component SemVer, no 'v' prefix." >&2
    exit 64
    ;;
esac

NS=${DCRE_NS:-dcre}

# The roster IS the diagrams (design-register R-49, verify-topology.sh). 28 stage
# services in three families, in the DAG order of each sheet, plus the
# cross-family HCS. RPT is not a stage: it is not launched as a Job, so it takes
# no AGT_<STAGE>_IMAGE.
STAGES_COLLECTIONS="CRR CTV CDE CRW CIR CIX CSX CPX CRG"
STAGES_PAYMENTS="PRR PTV PAI PRW PIR PIX PSX PPX PRG"
STAGES_MANDATES="MRR MRV MAS MIT MIR MRW MIX MSX MPX MRG"
STAGES_CROSS="HCS"

STAGES="$STAGES_COLLECTIONS $STAGES_PAYMENTS $STAGES_MANDATES $STAGES_CROSS"

# Positive control on the roster itself. A truncated or hand-edited constant
# would otherwise export a short list silently, and the fleet would come up with
# some stages still pointing at whatever image they held before.
n_col=$(echo "$STAGES_COLLECTIONS" | wc -w | tr -d ' ')
n_pay=$(echo "$STAGES_PAYMENTS"    | wc -w | tr -d ' ')
n_man=$(echo "$STAGES_MANDATES"    | wc -w | tr -d ' ')
n_all=$(echo "$STAGES"             | wc -w | tr -d ' ')
if [ "$n_col" -ne 9 ] || [ "$n_pay" -ne 9 ] || [ "$n_man" -ne 10 ] || [ "$n_all" -ne 29 ]; then
  echo "REFUSED: stage roster is not the diagrams' roster." >&2
  echo "  collections $n_col (want 9), payments $n_pay (want 9), mandates $n_man (want 10)," >&2
  echo "  total $n_all (want 29: 28 stage services + HCS)." >&2
  exit 70
fi

# Retired-name guard. Cheap, and it fires on the exact mistake this file was
# corrected for: a stale roster re-entering by copy-paste from an old runbook.
for dead in IXR SXR PXR AIS MAR MSR MIS MAF; do
  case " $STAGES " in
    *" $dead "*)
      echo "REFUSED: retired stage '$dead' is in the roster. Its image is not built." >&2
      exit 70 ;;
  esac
done

# `CURRENT=$(cmd); rc=$?` cannot be used under `set -e`: the failing assignment
# exits the script before the status is ever read. The status is captured in the
# `if` condition instead, where `set -e` is suspended, and it belongs to the
# kubectl get, not to any pipeline stage: there is no pipe here for that reason.
rc_get=0
CURRENT=$(kubectl get deploy dcre-agt -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}') || rc_get=$?
if [ "$rc_get" -ne 0 ] || [ -z "$CURRENT" ]; then
  echo "REFUSED: could not read the current dcre-agt image (kubectl get exit $rc_get)." >&2
  echo "Nothing was learned about the running fleet, so no switch is attempted." >&2
  exit 2
fi
CURRENT_TAG=${CURRENT##*:}

# Within-v1 downgrade guard. The pre-cutover guards (the 2.0 BUSINESS_FILE_REJECTED
# boundary, the 2.0.1 A-45 response-file collision, the 2.1+ one-directional line
# rule) all protected DURABLE ROWS written by an older service reading a newer
# seam. The v1 cutover dropped every database, so there are no such rows from any
# 2.x line left to protect and those guards are gone with the lines they guarded.
# The discipline itself is not gone: v1 minors stay one-directional from here, so
# a target below the running v1 version is refused for the same reason it always
# was, and the message says which two versions.
case "$CURRENT_TAG" in
  1.*.*)
    cur_minor=${CURRENT_TAG#*.}; cur_minor=${cur_minor%%.*}
    cur_patch=${CURRENT_TAG##*.}
    tgt_minor=${VERSION#*.};     tgt_minor=${tgt_minor%%.*}
    tgt_patch=${VERSION##*.}
    if [ "$tgt_minor" -lt "$cur_minor" ] ||
       { [ "$tgt_minor" -eq "$cur_minor" ] && [ "$tgt_patch" -lt "$cur_patch" ]; }; then
      echo "REFUSED: $CURRENT_TAG -> $VERSION is a downgrade within the v1 line." >&2
      echo "v1 minors are one-directional: an older AGT cannot read the newer" >&2
      echo "ledgers and would poison stage_outcome rows or double-launch intents." >&2
      exit 65
    fi
    ;;
  *)
    # Pre-cutover fleet still running. This IS the cutover switch, and it is the
    # one move across the boundary that is allowed, because the databases behind
    # the old fleet no longer exist.
    echo "NOTE: current AGT image is '$CURRENT' (pre-v1). Treating this as the"
    echo "      cutover switch onto the version 1 line."
    ;;
esac

echo "switching fleet $CURRENT_TAG -> $VERSION ($n_all images: $n_col collections,"
echo "$n_pay payments, $n_man mandates, 1 cross-family)"

# SCRUM-70 cutover: the AGT deployment must roll Recreate-style (strategy:
# Recreate in 10-agt-deployment.yml, i.e. old pod fully down before the new one
# starts) - NEVER RollingUpdate: two concurrent AGTs with different namespace
# views double-launch the same intents.
kubectl set image -n "$NS" deploy/dcre-agt "agt=dcre-agt:$VERSION"
for s in $STAGES; do
  lower=$(printf '%s' "$s" | tr 'A-Z' 'a-z')
  kubectl set env -n "$NS" deploy/dcre-agt "AGT_${s}_IMAGE=dcre-${lower}:$VERSION"
done
kubectl rollout status -n "$NS" deploy/dcre-agt --timeout=120s
echo "fleet switched to $VERSION"
