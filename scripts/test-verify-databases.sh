#!/usr/bin/env bash
# Red-proofs verify-databases.sh against a stub kubectl, so every branch is
# EXECUTED rather than reasoned about. The point of the script under test is
# that "could not query" (exit 2) and "genuinely absent" (exit 1) never look
# alike, and that claim is only worth what its failing cases prove.
#
# Each case asserts an EXACT exit code. "non-zero" would pass for reasons that
# mean the script never ran at all.
set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SUT="$HERE/verify-databases.sh"
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

# Stub kubectl: emits $STUB_OUT and exits $STUB_RC, ignoring its arguments.
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "$STUB/kubectl"

FULL='database_name
agt_ops
dcre_col
dcre_man
dcre_pay
defaultdb
postgres
system'

NO_PAY='database_name
agt_ops
dcre_col
dcre_man
defaultdb
postgres
system'

NO_CONTROL='database_name
agt_ops
dcre_col
dcre_man
dcre_pay'

# Everything present and correct EXCEPT the header, which is what a CockroachDB
# version bump or a --format change produces. Without the header-shape guard the
# script parses nothing and still declares PASS, so this fixture is the only one
# that holds that guard down.
BAD_HEADER='db_name
agt_ops
dcre_col
dcre_man
dcre_pay
defaultdb
postgres
system'

pass=0
fail=0

# $3, when given, is an extended-regex the script's own output must match. An
# exit code alone is a weak assertion: several different verdicts share one code,
# so a case can pass while the script says something quite wrong. Case 6 is the
# worked example, see its comment below.
check() {
  local casename="$1" want="$2" want_match="${3:-}" out got
  out=$(STUB_RC="$STUB_RC" STUB_OUT="$STUB_OUT" PATH="$STUB:$PATH" "$SUT" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    fail=$((fail + 1))
    printf 'FAIL exit=%s want=%s  %s\n%s\n' "$got" "$want" "$casename" "$out"
    return
  fi
  if [ -n "$want_match" ] && ! printf '%s\n' "$out" | grep -qE "$want_match"; then
    fail=$((fail + 1))
    printf 'FAIL exit=%s (ok) but output did not match /%s/  %s\n%s\n' \
      "$got" "$want_match" "$casename" "$out"
    return
  fi
  pass=$((pass + 1))
  printf 'ok   exit=%s  %s\n' "$got" "$casename"
}

STUB_RC=1 STUB_OUT=''            check 'query fails, no output -> unreadable'          2
STUB_RC=0 STUB_OUT=''            check 'exit 0 but silent -> unreadable'               2
STUB_RC=0 STUB_OUT='ERROR: connection refused' \
                                 check 'error text on stdout -> unreadable'            2
STUB_RC=0 STUB_OUT='database_name' \
                                 check 'header only, zero rows -> unreadable'          2
STUB_RC=0 STUB_OUT="$NO_CONTROL"  check 'control databases absent -> unreadable'        2

# A wrong header is what a CockroachDB version bump or a --format change looks
# like. With the header-shape guard removed this fixture exits 0 and prints
# "PASS: all present" over output the script never parsed, so the exit code is
# the assertion that matters and the message pins which guard produced it.
STUB_RC=0 STUB_OUT="$BAD_HEADER" \
  check 'valid body, wrong header -> unreadable, never PASS' 2 'unexpected output shape'

# The exit code alone is NOT sufficient here. The brief's original script also
# exits 1 on this fixture, but reports all four databases missing including three
# that are plainly in the listing. Asserting the absent list is exactly dcre_pay
# is what separates "found the one real absence" from "matcher is broken".
STUB_RC=0 STUB_OUT="$NO_PAY" \
  check 'read cleanly, dcre_pay absent -> missing' 1 'absent:[[:space:]]*dcre_pay$'

STUB_RC=0 STUB_OUT="$FULL"        check 'read cleanly, all present -> pass'             0

# The case the whole script exists for: a FAILED query that still put a
# plausible partial listing on stdout. Read as "queried, dcre_pay is missing"
# it produces exactly the A-79 misreport. It must be 2, never 1.
STUB_RC=1 STUB_OUT="$NO_PAY" \
  check 'failed query WITH partial output -> unreadable, never "missing"'              2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
