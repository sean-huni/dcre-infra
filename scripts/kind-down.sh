#!/bin/zsh
lsof -tiTCP:26258 -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
kind delete cluster --name dcre-dev
