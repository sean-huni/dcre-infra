#!/bin/zsh
# Switch the whole DCRE fleet between release versions (Sean-directed 2026-07-13).
#   1.0 = pre-M7 baseline   1.1 = +virtual threads   2.0 = +parallelism/dedup/acceptance-mode
# Fleet-wide only: never mix across the 2.0 boundary (2.0 AGT speaks
# BUSINESS_FILE_REJECTED; 1.x AGT does not). Stage images must be kind-loaded first.
#
# DOWNGRADE FORBIDDEN (Sean-ruled 2026-07-13): once the fleet is on 2.0, never
# switch AGT back to 1.x. A 1.x AGT reading a 2.0 CTV seam file records
# TECH_FAILED durably (stage_outcome is insert-once), permanently masking the
# real verdict; the arrival strands DAG_RUNNING and needs manual repair.
# The guard below enforces this; in-flight background work must be waited out,
# never terminated.
set -euo pipefail

VERSION=${1:-}
case "$VERSION" in
  1.0|1.1|2.0|2.0.1|2.1.0|2.2.0|2.3.0) ;;
  *) echo "usage: $0 <1.0|1.1|2.0|2.0.1|2.1.0|2.2.0|2.3.0>" >&2; exit 64 ;;
esac

NS=dcre

CURRENT=$(kubectl get deploy dcre-agt -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)
if [[ "$CURRENT" == 2.0* && "$VERSION" == 1.* ]]; then
  echo "REFUSED: fleet is on $CURRENT; downgrading AGT to $VERSION is forbidden (Sean-ruled 2026-07-13)." >&2
  echo "1.x AGT would durably poison stage_outcome rows for in-flight 2.0 arrivals." >&2
  exit 65
fi
if [[ "$CURRENT" == "2.0.1" && "$VERSION" == "2.0" ]]; then
  echo "REFUSED: 2.0 re-opens the A-45 response-file collision fixed in 2.0.1." >&2
  exit 65
fi

# Ordered line-boundary guard (SCRUM-79 review, replaces the direction-blind
# per-line guards that also refused upgrades): every minor line since 2.1 is
# one-directional (2.1 per-client tree + per-attempt outcome schema; 2.2 flow
# namespaces; 2.3 mandates stages MRR..MRG). Refuse ONLY a true downgrade,
# i.e. target major.minor line BELOW the current line; upgrades and same-line
# patch moves pass. Numeric compare, so 2.10 orders above 2.9. The legacy
# 1.x-poison and 2.0.1->2.0 (A-45) guards above stay as-is.
CUR_MAJOR=${CURRENT%%.*}
CUR_MINOR=${${CURRENT#*.}%%.*}
TGT_MAJOR=${VERSION%%.*}
TGT_MINOR=${${VERSION#*.}%%.*}
if (( TGT_MAJOR < CUR_MAJOR || (TGT_MAJOR == CUR_MAJOR && TGT_MINOR < CUR_MINOR) )); then
  echo "REFUSED: $CURRENT -> $VERSION crosses a release-line boundary downward." >&2
  echo "Each line since 2.1 is one-directional (2.1 per-client tree + attempt schema;" >&2
  echo "2.2 flow namespaces; 2.3 mandates stages MRR..MRG): an older AGT cannot read" >&2
  echo "the newer ledgers/Jobs and would poison outcomes or duplicate-launch live work." >&2
  exit 65
fi

STAGES=(CRR CTV CIR CDE CRW IXR SXR PXR PRG AIS HCS)

# M10 mandates family (SCRUM-79): dcre-m* images exist only from the 2.3
# release line. For older targets the AGT_M*_IMAGE envs are NOT set: pointing
# AGT_MRR_IMAGE at dcre-mrr:<old> would name a nonexistent image and wedge the
# launch, while absent/empty stays launch-disabled by config default.
if (( TGT_MAJOR > 2 || (TGT_MAJOR == 2 && TGT_MINOR >= 3) )); then
  STAGES+=(MRR MRV MAF MIS MIR MRW MIX MSX MPX MRG)
  # SCRUM-91: MAR and MSR are retired (split into MIX/MSX/MPX and replaced by the
  # derived views). They stay out of this list so no AGT_MAR_IMAGE/AGT_MSR_IMAGE is
  # ever exported; the Stage enum keeps them only so historic stage_outcome rows parse.
fi

# SCRUM-70 cutover: the AGT deployment must roll Recreate-style (strategy:
# Recreate in 10-agt-deployment.yml, i.e. old pod fully down before the new one
# starts) - NEVER RollingUpdate: two concurrent AGTs with different namespace
# views double-launch the same intents.
kubectl set image -n $NS deploy/dcre-agt agt=dcre-agt:$VERSION
for s in $STAGES; do
  kubectl set env -n $NS deploy/dcre-agt AGT_${s}_IMAGE=dcre-${(L)s}:$VERSION
done
kubectl rollout status -n $NS deploy/dcre-agt --timeout=120s
echo "fleet switched to $VERSION"
