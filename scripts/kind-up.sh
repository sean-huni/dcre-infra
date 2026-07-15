#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
kind create cluster --config k8s/kind-config.yml
# otel-lgtm is a multi-GB bundle; fresh kind nodes pull it for ~14 min (observed 2026-07-15),
# blowing the 240s rollout wait. Pre-pull on the host (cached across cluster cycles) and load.
docker image inspect grafana/otel-lgtm:0.29.0 > /dev/null 2>&1 || docker pull grafana/otel-lgtm:0.29.0
# kind load docker-image fails against Docker's containerd image store (multi-arch index
# references blobs docker save omits: "ctr: content digest ... not found", kind#3510;
# observed 2026-07-15). Save the server platform only and load the archive instead.
docker save --platform "linux/$(docker version --format '{{.Server.Arch}}')" grafana/otel-lgtm:0.29.0 \
  | kind load image-archive /dev/stdin --name dcre-dev
kubectl apply -k k8s/base
kubectl -n dcre rollout status statefulset/crdb --timeout=240s
kubectl -n dcre rollout status deploy/lgtm --timeout=240s
./scripts/crdb-forward.sh
./scripts/lgtm-forward.sh
echo "dcre-dev up."
