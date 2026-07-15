#!/bin/zsh
# Standalone/idempotent: (re)start the observability stack (Grafana + built-in
# Prometheus/Loki/Tempo, grafana/otel-lgtm) without touching the kind cluster.
# Also invoked by kind-up.sh.
#
# This is a compose container, not a k8s Service - it already host-publishes
# its ports directly (compose.yml), so no forward is needed once it's up.
# The actual failure mode here (found 2026-07-15) is different from CRDB's:
# the container OOM-kills under load and nobody notices, because an OTLP
# exporter fails open - AGT (OTEL_EXPORTER_OTLP_ENDPOINT -> host.docker.internal:4317)
# keeps running with telemetry silently dropped instead of erroring loudly.
# `docker compose up -d` restarts it whether it's Exited or never started.
set -e
cd "$(dirname "$0")/.."
UI_PORT=3000
docker compose up -d lgtm
echo "waiting for Grafana to answer..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$UI_PORT/api/health" >/dev/null 2>&1; then
    echo "Grafana up: http://localhost:$UI_PORT"
    echo "OTLP ingest: grpc http://localhost:4317, http http://localhost:4318"
    exit 0
  fi
  sleep 2
done
echo "WARNING: Grafana did not answer health check after 60s; check: docker compose logs lgtm" >&2
exit 1
