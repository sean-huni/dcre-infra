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

# 1. client role must NOT read OLTP
if $SQL --user=fnbcc01 --database=dcre_collections -e "SELECT count(*) FROM public.tx_entry" 2>/dev/null; then
  echo "FAIL: fnbcc01 read public.tx_entry"; fail=1
else
  echo "PASS: fnbcc01 denied on public.tx_entry"
fi

# 2. cross-client scoping on every rpt view
for v in $($SQL --database=dcre_collections -e "SELECT table_name FROM information_schema.views WHERE table_schema='rpt'" | tail -n +2); do
  n=$($SQL --user=fnbcc01 --database=dcre_collections -e "SELECT count(*) FROM rpt.${v} WHERE client <> 'FNBCC01'" | tail -1)
  if [[ "$n" != "0" ]]; then echo "FAIL: rpt.${v} leaked ${n} foreign rows to fnbcc01"; fail=1
  else echo "PASS: rpt.${v} scoped for fnbcc01"; fi
done

# 3. internal sees all clients
n=$($SQL --user=rpt_internal --database=dcre_collections -e "SELECT count(DISTINCT client) FROM rpt.v_tx" | tail -1)
[[ "$n" == "3" ]] && echo "PASS: rpt_internal sees 3 clients" || { echo "FAIL: rpt_internal sees ${n}"; fail=1; }

# 4. client role blind on ops views (fail-closed: no grant AND predicate)
if $SQL --user=fnbcc01 --database=agt_ops -e "SELECT count(*) FROM rpt.v_ops_stage_health" 2>/dev/null; then
  echo "FAIL: fnbcc01 read agt_ops ops view"; fail=1
else
  echo "PASS: fnbcc01 denied on ops views"
fi

exit $fail
