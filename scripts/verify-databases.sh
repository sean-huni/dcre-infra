#!/usr/bin/env bash
# Asserts every DCRE database exists on the cluster.
#
# Fails CLOSED, and the two failure modes are NEVER conflated:
#   exit 0  the listing was read and every expected database is present
#   exit 1  the listing was read and a database is genuinely absent
#   exit 2  the listing could not be read, or is not a trustworthy listing.
#           Nothing was learned about which databases exist.
#
# A-79: an earlier session read a failed query as a zero and recorded in a design
# document that dcre_pay existed and was empty. It did not exist at all. Every
# guard below exists to make that one mistake impossible, so none of them are
# defensive padding: each is the exact shape that misreport had.
set -u

NS="${DCRE_NS:-dcre}"
POD="${DCRE_CRDB_POD:-crdb-0}"
EXPECTED="agt_ops dcre_col dcre_man dcre_pay"

# Databases every CockroachDB cluster has. They are the positive control: an
# absence found by searching proves nothing until something proves the search
# can find. A listing without these is not a database listing, whatever exit
# status it arrived with, so it must not be read as "those databases are gone".
CONTROL="defaultdb system"

# Deliberately NOT a pipeline. `x=$(cmd | tail); rc=$?` captures tail's status,
# and tail succeeds on anything, so a failed query reads as a successful empty
# one. That substitution is the A-79 defect itself; the header is stripped below
# in-process instead, where no exit status can be lost.
RAW=$(kubectl exec -n "$NS" "$POD" -- ./cockroach sql --insecure --format=csv \
  -e "SELECT database_name FROM [SHOW DATABASES]" 2>/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "FAIL: could not query $NS/$POD (kubectl exit $rc)."
  echo "      This is NOT 'the database is missing'. Nothing was learned."
  exit 2
fi

if [ -z "$RAW" ]; then
  echo "FAIL: query exited 0 but returned no output at all."
  echo "      A silent empty result is a broken query, not an empty cluster."
  exit 2
fi

header="${RAW%%$'\n'*}"
header="${header//$'\r'/}"
if [ "$header" != "database_name" ]; then
  echo "FAIL: unexpected output shape. First line was '$header', expected 'database_name'."
  echo "      The output was not parsed, so no conclusion is drawn from it."
  exit 2
fi

if [ "$header" = "${RAW//$'\r'/}" ]; then
  echo "FAIL: header row only, zero data rows. A cluster with no databases at all"
  echo "      is not a state that exists; treat this as an unreadable listing."
  exit 2
fi

body="${RAW#*$'\n'}"
# Space-delimit with guaranteed leading and trailing spaces so every entry, not
# just the first and last, is surrounded by the separator the matcher looks for.
ACTUAL=" ${body//$'\n'/ } "
ACTUAL="${ACTUAL//$'\r'/}"

for db in $CONTROL; do
  case "$ACTUAL" in
    *" $db "*) ;;
    *) echo "FAIL: control database '$db' is absent from the listing."
       echo "      Every CockroachDB cluster has it, so this listing is not"
       echo "      trustworthy and cannot be read as evidence of any absence."
       echo "      got:$ACTUAL"
       exit 2 ;;
  esac
done

missing=""
for db in $EXPECTED; do
  case "$ACTUAL" in
    *" $db "*) ;;
    *) missing="$missing $db" ;;
  esac
done

if [ -n "$missing" ]; then
  echo "FAIL: listing read successfully; genuinely absent:$missing"
  echo "      present:$ACTUAL"
  exit 1
fi

echo "PASS: all present ($EXPECTED)"
