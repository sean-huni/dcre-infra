#!/bin/zsh
# Switch the whole DCRE fleet between release versions (Sean-directed 2026-07-13).
#   1.0 = pre-M7 baseline   1.1 = +virtual threads   2.0 = +parallelism/dedup/acceptance-mode
# Fleet-wide only: never mix across the 2.0 boundary (2.0 AGT speaks
# BUSINESS_FILE_REJECTED; 1.x AGT does not). Stage images must be kind-loaded first.
set -euo pipefail

VERSION=${1:-}
case "$VERSION" in
  1.0|1.1|2.0) ;;
  *) echo "usage: $0 <1.0|1.1|2.0>" >&2; exit 64 ;;
esac

NS=dcre
STAGES=(CRR CTV CIR CDE CRW IXR SXR PXR PRG AIS HCS)

kubectl set image -n $NS deploy/dcre-agt agt=dcre-agt:$VERSION
for s in $STAGES; do
  kubectl set env -n $NS deploy/dcre-agt AGT_${s}_IMAGE=dcre-${(L)s}:$VERSION
done
kubectl rollout status -n $NS deploy/dcre-agt --timeout=120s
echo "fleet switched to $VERSION"
