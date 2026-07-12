#!/bin/zsh
# Fintegrate simulator (ALLOWED stub: legitimate file-transfer simulation only).
# Polls fint-req for pain.008 files, replies with ISR/SBSR/PBSR into fint-resp
# (via fint_sim_reply.py), archives the consumed request.
setopt NULL_GLOB
cd "$(dirname "$0")/.."
mkdir -p exchange/fint-resp exchange/archive/fint-sim
while true; do
  for f in exchange/fint-req/*_PAIN008.xml; do
    base=$(basename "$f" _PAIN008.xml)
    python3 scripts/fint_sim_reply.py "$f" "$base" exchange/fint-resp
    mv "$f" exchange/archive/fint-sim/
  done
  sleep 3
done
