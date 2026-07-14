#!/bin/zsh
# Fintegrate simulator (ALLOWED stub: legitimate file-transfer simulation only).
# Per-client (SCRUM-42): for each client base, polls <base>/fint-req/out for pain.008
# files, replies with ISR/SBSR/PBSR into <base>/fint-resp/in (via fint_sim_reply.py),
# archives the consumed request to <base>/fint-req/archive. The reply script is unchanged
# (the client stays a filename token; the 2nd arg is the stem without _PAIN008.xml).
setopt NULL_GLOB
cd "$(dirname "$0")/.."
clients=(fnbcc01 fnbcc02 fnbrf01)
for c in $clients; do
  mkdir -p "exchange/$c/fint-resp/in" "exchange/$c/fint-req/archive"
done
while true; do
  for c in $clients; do
    for f in exchange/$c/fint-req/out/*_PAIN008.xml; do
      stem=$(basename "$f" _PAIN008.xml)
      python3 scripts/fint_sim_reply.py "$f" "$stem" "exchange/$c/fint-resp/in"
      mv "$f" "exchange/$c/fint-req/archive/"
    done
  done
  sleep 3
done
