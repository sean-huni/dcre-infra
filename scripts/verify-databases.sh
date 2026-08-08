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
# FIVE databases. A database is named for the CONTEXT that owns it. The three
# family databases keep family names because nine or ten services share each; a
# single-service context takes the SERVICE's name, hence dcre_hcs (holidays,
# owner hcs) rather than a topic name.
#
# dcre_acs WAS HERE FOR ONE DAY AND IS DELIBERATELY GONE. The account registry
# service that owned it was retired on 2026-08-09: it had no authoritative
# source, no accountable owner, no ingestion of its own and no freshness
# contract, so it was a shared integration database wearing the costume of a
# bounded context, and it made the first validation gate of all three families
# depend at runtime on 110 static fixture rows. Account reference data now
# travels as ONE immutable versioned artifact (fixtures/reference/account/) and
# each context materialises its OWN projection into its OWN database. hcs stays,
# because unlike acs it ingests from a real upstream (Nager.Date, six-hour sync)
# and has an accountable owner.
#
# If this list ever grows a sixth entry again, the question to ask first is what
# that context INGESTS and who owns it. A database holding rows nothing produces
# is a shared table with extra network hops.
EXPECTED="agt_ops dcre_col dcre_man dcre_pay dcre_hcs"

# Databases every CockroachDB cluster has. They are the positive control: an
# absence found by searching proves nothing until something proves the search
# can find. A listing without these is not a database listing, whatever exit
# status it arrived with, so it must not be read as "those databases are gone".
CONTROL="defaultdb system"

# Deliberately NOT a pipeline. `x=$(cmd | tail); rc=$?` captures tail's status,
# and tail succeeds on anything, so a failed query reads as a successful empty
# one. That substitution is the A-79 defect itself; the header is stripped below
# in-process instead, where no exit status can be lost.
#
# --database=defaultdb is EXPLICIT even though SHOW DATABASES is cluster-scoped
# and would answer identically from any connection database. The rule in this
# repo has no "harmless read" exemption: an earlier env-reset let the connection
# database default and put 22 Liquibase history tables into defaultdb while its
# verify step correctly found zero. defaultdb is chosen because it is the one
# database this project never drops, so this call cannot fail for want of its
# own connection target while checking whether the others exist.
RAW=$(kubectl exec -n "$NS" "$POD" -- ./cockroach sql --insecure \
  --database=defaultdb --format=csv \
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
