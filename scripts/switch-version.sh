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
  1.0|1.1|2.0|2.0.1|2.1.0|2.2.0) ;;
  *) echo "usage: $0 <1.0|1.1|2.0|2.0.1|2.1.0|2.2.0>" >&2; exit 64 ;;
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
STAGES=(CRR CTV CIR CDE CRW IXR SXR PXR PRG AIS HCS)


# 2.1.0 guard: per-client exchange tree + per-attempt outcome schema (005) make any
# downgrade from 2.1.0 unsafe (older stages read the flat tree; older AGT cannot
# read per-attempt outcomes).
if [[ "$CURRENT" == 2.1* && "$VERSION" != 2.1* ]]; then
  echo "REFUSED: downgrade from $CURRENT to $VERSION (per-client tree + attempt schema)" >&2
  exit 65
fi

# 2.2 guard (SCRUM-70, one-directional): 2.2 launches stage Jobs into the flow
# namespaces (dcre-col/dcre-pay/dcre-man). A pre-2.2 AGT only watches namespace
# dcre: it cannot see still-running col-/pay- Jobs, so after REAP_GRACE it would
# relaunch duplicates of live work = concurrent same-identity execution.
if [[ "$CURRENT" == 2.2* && "$VERSION" != 2.2* ]]; then
  echo "REFUSED: downgrade from $CURRENT to $VERSION (flow namespaces: pre-2.2 AGT" >&2
  echo "cannot see col-/pay-/man- Jobs and would duplicate-launch running work)" >&2
  exit 65
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
