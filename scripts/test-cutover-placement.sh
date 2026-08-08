#!/usr/bin/env bash
# Red-proofs the relation-PLACEMENT half of cutover-v1.sh's isolation audit
# (SCRUM-107) against a stub kubectl, so every branch is EXECUTED rather than
# reasoned about. Companion to test-verify-databases.sh and built the same way.
#
# What it holds down, and why each case exists:
#   - the four verdicts never look alike: 0 clean, 1 assertion failed,
#     2 INSTRUMENT failed, 3 pending
#   - an INSTRUMENT failure says so IN THOSE WORDS and is never reported as the
#     assertion having failed. Those are different claims: one is about the
#     search, the other about the database
#   - an absence in an EMPTY database is PENDING, never PASS, because "zero
#     relations named public_holiday" is trivially true of a database with
#     nothing in it
#   - the placement universe includes VIEWS. A compatibility view named
#     `account` left behind in dcre_col is the most likely way for the move to
#     be incomplete, and a BASE-TABLE-only search cannot see it
#
# Each case asserts an EXACT exit code AND a message. The exit code alone is a
# weak assertion here: 1 is returned by both halves of the audit, so a case can
# pass while the script says something quite wrong.
set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SUT="$HERE/cutover-v1.sh"
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

# ---------------------------------------------------------------------------
# Stub kubectl. Answers the cluster guard, then dispatches `cockroach sql` on
# the SQL text. Per-database relations come from TBL_<db> (base tables) and
# VW_<db> (views); the all-relations listing is the union, which is exactly the
# distinction the placement universe turns on.
# ---------------------------------------------------------------------------
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
  config)
    case "${2:-}" in
      current-context) echo "kind-dcre-dev"; exit 0 ;;
      view)            echo "kind-dcre-dev"; exit 0 ;;
    esac ;;
  get) echo "dcre-dev-control-plane"; exit 0 ;;
esac

db=""; sql=""; prev=""
for a in "$@"; do
  case "$a" in --database=*) db="${a#--database=}" ;; esac
  [ "$prev" = "-e" ] && sql="$a"
  prev="$a"
done

# A cockroach call that reached here without an explicit --database is the exact
# defect this project keeps re-learning, so the stub refuses rather than guesses.
if [ -z "$db" ]; then
  echo "STUB ERROR: cockroach sql invoked with no --database=" >&2
  exit 99
fi

emit() { echo "table_name"; for r in $1; do [ -n "$r" ] && echo "$r"; done; }
lookup() { local v="$1_$2"; echo "${!v:-}"; }

case "$sql" in
  *"SHOW DATABASES"*)
    echo "database_name"
    for d in ${STUB_DATABASES:-}; do echo "$d"; done
    exit 0 ;;
  *"SHOW JOBS"*)
    echo "count"; echo "0"; exit 0 ;;
  *"count(*)"*"information_schema"*)
    echo "count"; echo "${STUB_ISCHEMA_COUNT:-250}"; exit 0 ;;
  *"table_name IN ('tables','columns','schemata')"*)
    # The instrument control. STUB_BREAK_INSTRUMENT names the database whose
    # catalog search is sabotaged: it answers 0 rows while exiting 0, which is
    # the shape a broken search has when nothing complains.
    if [ "${STUB_BREAK_INSTRUMENT:-}" = "$db" ]; then emit ""; else emit "columns schemata tables"; fi
    exit 0 ;;
  *"table_type='BASE TABLE'"*)
    emit "$(lookup TBL "$db")"; exit 0 ;;
  *"table_schema='public'"*)
    emit "$(lookup TBL "$db") $(lookup VW "$db")"; exit 0 ;;
esac
echo "STUB ERROR: unhandled SQL: $sql" >&2
exit 98
STUBEOF
chmod +x "$STUB/kubectl"

# ---------------------------------------------------------------------------
# Fixtures: a correct post-cutover cluster. Cases below mutate one thing each.
# ---------------------------------------------------------------------------
ALL_DBS='agt_ops dcre_col dcre_hcs dcre_man dcre_pay defaultdb postgres system'

base_fixture() {
  STUB_DATABASES="$ALL_DBS"
  # `account` appears in THREE databases and that is correct: three contexts
  # each materialise their own PROJECTION of one versioned artifact into their
  # own table. `account_type` appears in dcre_man ONLY, because it is a closed
  # vocabulary the mandates changelogs seed and no loader touches.
  TBL_dcre_col='crr_databasechangelog ctv_databasechangelog cde_databasechangelog stage_outcome tx_entry account account_reference_load'
  TBL_dcre_pay='prr_databasechangelog ptv_databasechangelog prg_databasechangelog account account_reference_load'
  TBL_dcre_man='mrr_databasechangelog mrv_databasechangelog mandate_reason_code account account_type account_reference_load'
  TBL_dcre_hcs='hcs_databasechangelog public_holiday'
  TBL_agt_ops='rpt_databasechangelog agt_job'
  VW_dcre_col=''; VW_dcre_pay=''; VW_dcre_man=''
  VW_dcre_hcs=''; VW_agt_ops=''
  STUB_ISCHEMA_COUNT=250
  STUB_BREAK_INSTRUMENT=''
  export STUB_DATABASES TBL_dcre_col TBL_dcre_pay TBL_dcre_man TBL_dcre_hcs \
         TBL_agt_ops VW_dcre_col VW_dcre_pay VW_dcre_man \
         VW_dcre_hcs VW_agt_ops STUB_ISCHEMA_COUNT STUB_BREAK_INSTRUMENT
}

pass=0
fail=0

# $3 is an extended-regex the script's own output must match. Asserting the
# message is what separates "returned 1" from "returned 1 FOR THE RIGHT REASON":
# both halves of the audit return 1.
check() {
  local casename="$1" want="$2" want_match="${3:-}" forbid="${4:-}" out got
  out=$(PATH="$STUB:$PATH" bash "$SUT" --audit-only 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    fail=$((fail + 1))
    printf 'FAIL exit=%s want=%s  %s\n%s\n\n' "$got" "$want" "$casename" "$out"
    return
  fi
  if [ -n "$want_match" ] && ! printf '%s\n' "$out" | grep -qE "$want_match"; then
    fail=$((fail + 1))
    printf 'FAIL exit=%s (ok) but output did not match /%s/  %s\n%s\n\n' \
      "$got" "$want_match" "$casename" "$out"
    return
  fi
  if [ -n "$forbid" ] && printf '%s\n' "$out" | grep -qE "$forbid"; then
    fail=$((fail + 1))
    printf 'FAIL exit=%s (ok) but output WRONGLY matched /%s/  %s\n%s\n\n' \
      "$got" "$forbid" "$casename" "$out"
    return
  fi
  pass=$((pass + 1))
  printf 'ok   exit=%s  %s\n' "$got" "$casename"
}

# --- the happy path, first, so a harness that cannot pass is visible ---------
base_fixture
check 'correct post-cutover cluster -> clean' 0 \
  'RESULT: every context database holds its own objects'

# --- public_holiday belongs to dcre_hcs alone --------------------------------
base_fixture
TBL_dcre_col="$TBL_dcre_col public_holiday"; export TBL_dcre_col
check 'public_holiday left behind in dcre_col -> assertion failed' 1 \
  'ASSERTION FAILED: dcre_col holds relations that must not exist there: public_holiday'

# --- each context MUST hold its own account projection -----------------------
# The assertion inverted on 2026-08-09. `account` missing from a populated
# context database used to be the healthy state and is now the defect: that
# context's loader has not run, so its validators resolve every account against
# an empty or absent relation.
base_fixture
TBL_dcre_col='crr_databasechangelog ctv_databasechangelog stage_outcome tx_entry'
export TBL_dcre_col
check 'dcre_col populated but missing its account projection -> assertion failed' 1 \
  'missing relations it must own: account'

base_fixture
TBL_dcre_pay='prr_databasechangelog ptv_databasechangelog prg_databasechangelog'
export TBL_dcre_pay
check 'dcre_pay populated but missing its account projection -> assertion failed' 1 \
  'missing relations it must own: account'

base_fixture
TBL_dcre_man='mrr_databasechangelog mrv_databasechangelog mandate_reason_code account'
export TBL_dcre_man
check 'dcre_man populated but missing account_type -> assertion failed' 1 \
  'missing relations it must own: account_type'

# --- account_type is the MANDATES vocabulary and travels nowhere -------------
# It is not part of the artifact, so a copy in a collections-shape database
# means somebody widened a loader past its projection.
base_fixture
TBL_dcre_col="$TBL_dcre_col account_type"; export TBL_dcre_col
check 'account_type wrongly copied into dcre_col -> assertion failed' 1 \
  'ASSERTION FAILED: dcre_col holds relations that must not exist there: account_type'

# The case a BASE-TABLE-only universe is structurally blind to. If this passes
# while the table-only variant does not, the table_type filter has been
# reintroduced and the most likely incomplete move is invisible again.
base_fixture
VW_dcre_pay='account_type'; export VW_dcre_pay
check 'account_type appears in dcre_pay as a VIEW -> assertion failed' 1 \
  'ASSERTION FAILED: dcre_pay holds relations that must not exist there: account_type'

base_fixture
TBL_dcre_hcs='hcs_databasechangelog public_holiday account'; export TBL_dcre_hcs
check 'account wrongly in dcre_hcs -> assertion failed' 1 \
  'ASSERTION FAILED: dcre_hcs holds relations that must not exist there: account'

# --- empty databases are PENDING, never PASS ---------------------------------
# The whole point of the content control. dcre_col holding nothing satisfies
# "zero relations named public_holiday" trivially, and reporting that as a pass
# is the misreport this project keeps re-learning.
base_fixture
TBL_dcre_col=''; export TBL_dcre_col
check 'dcre_col empty -> PENDING, never PASS' 3 \
  'PENDING: expected relations absent' \
  'RESULT: every context database holds its own objects'

# The CONTENT CONTROL itself, which the empty-database case above no longer
# reaches: every database now has a want-present list, and that check returns
# before the absence is judged. So the control is exercised by a database that
# HOLDS its required relation and nothing else. Without this case the control
# would be a guard nothing executes, which is how the dead ALLOWED_* constants
# in verify-topology.sh drifted unnoticed for weeks.
base_fixture
TBL_dcre_col='account'; export TBL_dcre_col
check 'dcre_col holds account but no history tables -> control found NONE, PENDING' 3 \
  'PENDING: the content control found NONE' \
  'RESULT: every context database holds its own objects'

base_fixture
TBL_dcre_hcs=''; export TBL_dcre_hcs
check 'dcre_hcs empty -> PENDING, not a missing-relation violation' 3 \
  'PENDING: expected relations absent'

# --- a broken instrument is never an assertion failure -----------------------
# The distinction the brief turns on: the search did not run, so nothing was
# asserted. It must exit 2 and say INSTRUMENT, and must NOT say the assertion
# failed, because no assertion was evaluated.
base_fixture
STUB_BREAK_INSTRUMENT='dcre_col'; export STUB_BREAK_INSTRUMENT
check 'catalog search broken for dcre_col -> INSTRUMENT failed, not assertion' 2 \
  'dcre_col: INSTRUMENT FAILED' \
  'ASSERTION FAILED'

base_fixture
STUB_BREAK_INSTRUMENT='dcre_man'; export STUB_BREAK_INSTRUMENT
check 'catalog search broken for dcre_man -> INSTRUMENT failed, not assertion' 2 \
  'dcre_man: INSTRUMENT FAILED' \
  'ASSERTION FAILED'

# --- a violation outranks a pending ------------------------------------------
# Severity is a ranking, not a numeric max: a real violation must not be
# reported as "merely unfinished" because some other database has not built yet.
base_fixture
TBL_dcre_hcs=''; export TBL_dcre_hcs
TBL_dcre_col="$TBL_dcre_col public_holiday"; export TBL_dcre_col
check 'violation alongside a pending -> reported as the violation' 1 \
  'ASSERTION FAILED: dcre_col holds relations'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
