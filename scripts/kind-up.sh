#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
kind create cluster --config k8s/kind-config.yml
kubectl apply -k k8s/base
kubectl -n dcre rollout status statefulset/crdb --timeout=240s
echo "dcre-dev up."
