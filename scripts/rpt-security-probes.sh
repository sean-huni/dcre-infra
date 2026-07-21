#!/bin/zsh
# Negative security probes for the rpt reporting schema (spec section 9 gate 6).
# Requires crdb-forward (26258). Exits non-zero on ANY unexpected access result.
set -e
cd "$(dirname "$0")/.."
# zsh array (not a scalar): $SQL then expands to separate words. A scalar string
# would be treated as one command name under zsh (no word splitting), so the
# probes would never run and their negative checks would falsely PASS.
SQL=(kubectl -n dcre exec crdb-0 -- ./cockroach sql --insecure --format=csv)
fail=0

# 1. client role must NOT read OLTP.
# Assert the DENY is a real permission error (SQLSTATE 42501), not merely a
# non-zero exit: a dropped role / renamed pod / down forward would exit non-zero
# and false-PASS a security assertion. Capture combined output; PASS only if it
# contains 42501. `|| true` keeps set -e from aborting on the (expected) exit 1.
out=$($SQL --user=fnbcc01 --database=dcre_col -e "SELECT count(*) FROM public.tx_entry" 2>&1) || true
if [[ "$out" == *42501* ]]; then
  echo "PASS: fnbcc01 denied on public.tx_entry"
else
  echo "FAIL: fnbcc01 not denied with 42501 on public.tx_entry ($out)"; fail=1
fi

# 2. cross-client scoping on every rpt view
for v in $($SQL --database=dcre_col -e "SELECT table_name FROM information_schema.views WHERE table_schema='rpt'" | tail -n +2); do
  n=$($SQL --user=fnbcc01 --database=dcre_col -e "SELECT count(*) FROM rpt.${v} WHERE client <> 'FNBCC01'" | tail -1)
  if [[ "$n" != "0" ]]; then echo "FAIL: rpt.${v} leaked ${n} foreign rows to fnbcc01"; fail=1
  else echo "PASS: rpt.${v} scoped for fnbcc01"; fi
done

# 2b. non-emptiness canary. The scoping check above is trivially true on an
# EMPTY view (count WHERE client<>own = 0), so a regression that emptied a view
# would still PASS. Assert fnbcc01 actually SEES its own rows in the two views
# guaranteed non-empty for a client with transactions. Only these two qualify:
# v_cure / v_recon can legitimately be empty for a client, so are NOT canaries.
ntx=$($SQL --user=fnbcc01 --database=dcre_col -e "SELECT count(*) FROM rpt.v_tx" | tail -1)
ntd=$($SQL --user=fnbcc01 --database=dcre_col -e "SELECT count(*) FROM rpt.v_tx_daily" | tail -1)
if [[ "$ntx" -gt 0 && "$ntd" -gt 0 ]]; then
  echo "PASS: fnbcc01 canary non-empty (v_tx=${ntx}, v_tx_daily=${ntd})"
else
  echo "FAIL: fnbcc01 canary empty (v_tx=${ntx}, v_tx_daily=${ntd})"; fail=1
fi

# 3. internal sees all clients
n=$($SQL --user=rpt_internal --database=dcre_col -e "SELECT count(DISTINCT client) FROM rpt.v_tx" | tail -1)
[[ "$n" == "3" ]] && echo "PASS: rpt_internal sees 3 clients" || { echo "FAIL: rpt_internal sees ${n}"; fail=1; }

# 4. client role blind on ops views (fail-closed: no grant AND predicate).
# Same 42501 assertion as probe 1: a non-permission error must FAIL, not PASS.
out=$($SQL --user=fnbcc01 --database=agt_ops -e "SELECT count(*) FROM rpt.v_ops_stage_health" 2>&1) || true
if [[ "$out" == *42501* ]]; then
  echo "PASS: fnbcc01 denied on ops views"
else
  echo "FAIL: fnbcc01 not denied with 42501 on agt_ops ops view ($out)"; fail=1
fi

exit $fail
