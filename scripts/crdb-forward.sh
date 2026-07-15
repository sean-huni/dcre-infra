#!/bin/zsh
# Standalone/idempotent: (re)establish the CRDB port-forward without touching
# the cluster. Also invoked by kind-up.sh at the end of a fresh bring-up.
# CRDB is ClusterIP-only (no kind hostPort mapping) so local tools (DataGrip,
# psql) need this. Recurring failure mode: the forward dies silently (shell
# closed, laptop slept) leaving the cluster healthy but unreachable from the
# host - the fix each time was just "start the forward again", so it's a
# script now instead of a manual command.
set -e
PF_PORT=26258
PF_LOG=/tmp/dcre-crdb-portforward.log
lsof -tiTCP:$PF_PORT -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
sleep 1
nohup kubectl -n dcre port-forward svc/crdb $PF_PORT:26257 > "$PF_LOG" 2>&1 &
disown
sleep 2
if lsof -tiTCP:$PF_PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "CRDB port-forward up: localhost:$PF_PORT -> svc/crdb:26257 (log: $PF_LOG)"
  echo "DataGrip / psql: jdbc:postgresql://localhost:$PF_PORT/dcre_collections?sslmode=disable (user root, no password)"
else
  echo "WARNING: CRDB port-forward failed to start; check $PF_LOG" >&2
  exit 1
fi
