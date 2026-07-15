#!/bin/zsh
# Forward in-cluster Grafana (svc/lgtm 3000) to host 3001.
# Host 3000 stays reserved for the compose LGTM (inner loop).
set -e
cd "$(dirname "$0")/.."
lsof -tiTCP:3001 -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
PF_LOG=/tmp/dcre-lgtm-portforward.log
nohup kubectl -n dcre port-forward svc/lgtm 3001:3000 > "$PF_LOG" 2>&1 &
disown
for i in $(seq 1 30); do
  curl -sf http://localhost:3001/api/health > /dev/null 2>&1 && { echo "lgtm forward up: http://localhost:3001"; exit 0; }
  sleep 2
done
echo "WARNING: lgtm forward failed; see $PF_LOG" >&2
exit 1
