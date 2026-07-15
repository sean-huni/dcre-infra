#!/bin/zsh
# Standalone/idempotent: (re)establish the CRDB port-forwards without touching
# the cluster. Also invoked by kind-up.sh at the end of a fresh bring-up.
# CRDB is ClusterIP-only (no kind hostPort mapping) so local tools (DataGrip,
# psql, browser) need this. Recurring failure mode: the forward dies silently
# (shell closed, laptop slept) leaving the cluster healthy but unreachable
# from the host - the fix each time was just "start the forward again", so
# it's a script now instead of a manual command.
#
# Forwards both the SQL port and the DB Console (browser GUI). Host ports
# match the compose stack's own mapping (8081->8080) so a bookmark/habit
# works the same whether the day's dev env is kind or compose.
set -e
SQL_PORT=26258
CONSOLE_PORT=8081
PF_LOG=/tmp/dcre-crdb-portforward.log

for p in $SQL_PORT $CONSOLE_PORT; do
  lsof -tiTCP:$p -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
done
sleep 1
nohup kubectl -n dcre port-forward svc/crdb $SQL_PORT:26257 $CONSOLE_PORT:8080 > "$PF_LOG" 2>&1 &
disown
sleep 2

ok=1
for p in $SQL_PORT $CONSOLE_PORT; do
  lsof -tiTCP:$p -sTCP:LISTEN >/dev/null 2>&1 || ok=0
done
if [ "$ok" = "1" ]; then
  echo "CRDB port-forward up (log: $PF_LOG)"
  echo "  SQL:     jdbc:postgresql://localhost:$SQL_PORT/dcre_collections?sslmode=disable (user root, no password)"
  echo "  Console: http://localhost:$CONSOLE_PORT"
else
  echo "WARNING: CRDB port-forward failed to start; check $PF_LOG" >&2
  exit 1
fi
