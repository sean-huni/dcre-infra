#!/bin/zsh
# Fintegrate simulator (ALLOWED stub: legitimate file-transfer simulation only).
# Per-client (SCRUM-42): for each client base, polls <base>/fint-req/out for pain.008
# files, replies with ISR/SBSR/PBSR into <base>/fint-resp/in (via fint_sim_reply.py),
# archives the consumed request to <base>/fint-req/archive. The reply script is unchanged
# (the client stays a filename token; the 2nd arg is the stem without _PAIN008.xml).
#
# M10 T10 mandates leg: also polls <base>/fint-req-man/out for the mrw outbound
# pain.009/.010/.011 (one mandate per message) and replies with a pain.012 ISR/SBSR/PBSR
# trio into <base>/fint-resp-man/in (fint_sim_reply.py --mandate), matching on the
# out_msg_id stem (the filename minus the _PAIN00x token), then archives the request.
setopt NULL_GLOB
cd "$(dirname "$0")/.."
clients=(fnbcc01 fnbcc02 fnbrf01)
man_pains=(PAIN009 PAIN010 PAIN011)
for c in $clients; do
  mkdir -p "exchange/$c/fint-resp/in" "exchange/$c/fint-req/archive" \
           "exchange/$c/fint-resp-man/in" "exchange/$c/fint-req-man/archive"
done
while true; do
  for c in $clients; do
    for f in exchange/$c/fint-req/out/*_PAIN008.xml; do
      stem=$(basename "$f" _PAIN008.xml)
      python3 scripts/fint_sim_reply.py "$f" "$stem" "exchange/$c/fint-resp/in"
      mv "$f" "exchange/$c/fint-req/archive/"
    done
    for pt in $man_pains; do
      for f in exchange/$c/fint-req-man/out/*_${pt}.xml; do
        stem=$(basename "$f" "_${pt}.xml")
        python3 scripts/fint_sim_reply.py --mandate "$f" "$stem" "exchange/$c/fint-resp-man/in"
        mv "$f" "exchange/$c/fint-req-man/archive/"
      done
    done
  done
  sleep 3
done
