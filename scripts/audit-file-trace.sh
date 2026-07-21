#!/bin/zsh
# SCRUM-58 file-trace resolution audit (spec 2026-07-16-file-trace-design.md sections 0.1 F2 + 2.9).
#
# THE GATE: after an e2e / chaos run, every file under the exchange root MUST resolve to >= 1 owner
# record via the file-trace killer query (scripts/file-trace-query.sql). A file that returns zero
# rows is an untraceable boundary file -- a capture-layer hole -- and fails the build. This is the
# third F2 enforcement layer (alongside the rpt FileTraceViewIT conformance matrix and the
# platform-files capture contract).
#
# USAGE:
#   scripts/audit-file-trace.sh [exchange_root]
#
# Chaos-harness wiring (post-run gate step): call it and check the exit code, e.g.
#   scripts/audit-file-trace.sh || { echo "trace gate failed"; exit 1; }
#
# CONFIG (12-factor; committed defaults target the kind cluster like rpt-security-probes.sh):
#   exchange_root arg  or  DCRE_EXCHANGE_ROOT   the exchange root to scan   (default: <repo>/exchange)
#   DCRE_COCKROACH     connection command prefix                            (default: in-cluster kubectl exec)
#   CRDB_USER          role to run as (must be rpt_internal or root)        (default: rpt_internal)
#   CRDB_DATABASE      database passed explicitly per the ops rule          (default: dcre_col)
#   DCRE_TRACE_QUERY   killer-query file to run                             (default: scripts/file-trace-query.sql)
# Overrides for the local inner loop:
#   DCRE_COCKROACH="cockroach sql --insecure --host=localhost:26257"          # compose stack
#   DCRE_COCKROACH="docker exec <crdb-container> cockroach sql --insecure"    # isolated container
#
# EXIT: 0 = every file resolves; 1 = one or more unresolved; 2 = config error; 3 = query/connection error.
#
# DEVIATIONS from a literal "every file under the exchange root" (all faithful to the intent):
#   * EXCLUDES paths under inflight/ and *.tmp files -- spec's declared partial-write exclusions.
#   * EXCLUDES any hidden component (.gitkeep placeholders, exchange/.reset-stamp infra marker,
#     exchange/.staging-drop atomic tmp+rename staging). These are non-deliverable / partial-write
#     artifacts, the SAME class as inflight/*.tmp; without this every .gitkeep would false-fail the
#     gate. Documented, deliberate.
#   * The database is passed explicitly (--database) per the ops-scripting rule; the query itself
#     resolves everything through fully-qualified <db>.rpt.<view> 3-part names, so the session db
#     is otherwise irrelevant. No persisted cross-DB view is used.
#   * error/ and duplicates/ on-disk names carry a leading strict-UUID '<uuid>_' claim prefix; the
#     owner tables store the BARE name (quarantine row-id fix: the uuid IS the arrival/claim id), so
#     the prefix is stripped before querying (spec section 3 prefix note).
emulate -L zsh
setopt pipe_fail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h}
QUERY_FILE=${DCRE_TRACE_QUERY:-$SCRIPT_DIR/file-trace-query.sql}
EXCHANGE_ROOT=${1:-${DCRE_EXCHANGE_ROOT:-$REPO_ROOT/exchange}}
CRDB_DATABASE=${CRDB_DATABASE:-dcre_col}
CRDB_USER=${CRDB_USER:-rpt_internal}
: ${DCRE_COCKROACH:="kubectl -n dcre exec crdb-0 -- ./cockroach sql --insecure"}
# zsh ARRAY via forced word-split (${=...}); a scalar would be exec'd as one command name and fail.
cockroach_base=(${=DCRE_COCKROACH})

[[ -d $EXCHANGE_ROOT ]] || { print -u2 -- "ERROR: exchange root not found: $EXCHANGE_ROOT"; exit 2; }
[[ -r $QUERY_FILE ]]    || { print -u2 -- "ERROR: query file not readable: $QUERY_FILE"; exit 2; }
QUERY_TEMPLATE=$(<"$QUERY_FILE")

# Run the killer query for one bare file name; echo the number of result rows, or return 2 on a
# connection/SQL failure (distinct from a legitimate zero-row / untraceable result).
run_count() {
  local fname=$1
  local esc=${fname//\'/\'\'}                       # SQL-escape: double any single quote
  local sql=${QUERY_TEMPLATE//:fname/\'$esc\'}      # substitute the :fname placeholder (quoted literal)
  local out
  out=$("${cockroach_base[@]}" --database="$CRDB_DATABASE" --user="$CRDB_USER" --format=csv -e "$sql" 2>&1)
  if (( $? != 0 )); then
    print -u2 -- "  cockroach error while resolving '$fname':"
    print -u2 -- "$out"
    return 2
  fi
  # --format=csv emits one header row then N data rows. grep -c counts every line (robust to a
  # missing final newline, unlike wc -l). Data rows = lines - header.
  local total=$(print -r -- "$out" | grep -c '')
  local data=$(( total - 1 ))
  (( data < 0 )) && data=0
  print -r -- "$data"
  return 0
}

uuid_prefix='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}_'

# The scan runs inside a function so every `local` is properly function-scoped and declared once;
# a top-level `local` re-declared each loop pass makes zsh echo the param's prior value to stdout.
main() {
  # NUL-delimited enumeration into an array (a `find | while` pipeline would run the loop in a zsh
  # subshell and the collected results would be lost).
  local -a files
  files=( ${(0)"$(find "$EXCHANGE_ROOT" -type f \
                       -not -path '*/inflight/*' \
                       -not -path '*/.*' \
                       -not -name '*.tmp' \
                       -print0)"} )

  local -A verdict
  local -a unresolved
  integer scanned=0 queried=0
  local p base logical rows

  for p in $files; do
    (( scanned += 1 ))
    base=${p:t}
    logical=$base
    [[ $base =~ $uuid_prefix ]] && logical=${base#*_}   # strip '<uuid>_' claim prefix (error/duplicates)

    if [[ -n ${verdict[$logical]:-} ]]; then
      [[ ${verdict[$logical]} == FAIL ]] && unresolved+=("$p")
      continue
    fi

    (( queried += 1 ))
    rows=$(run_count "$logical")
    if (( $? == 2 )); then
      print -u2 -- "ERROR: trace query failed (connection/SQL) -- aborting audit."
      exit 3
    fi
    if (( rows >= 1 )); then
      verdict[$logical]=OK
    else
      verdict[$logical]=FAIL
      unresolved+=("$p")
    fi
  done

  print -- "file-trace audit: root=$EXCHANGE_ROOT scanned=$scanned queried=$queried unresolved=${#unresolved}"
  if (( ${#unresolved} > 0 )); then
    print -u2 -- "UNRESOLVED (0 rows from the killer query -- untraceable boundary files):"
    for u in $unresolved; do print -u2 -- "  $u"; done
    exit 1
  fi
  print -- "PASS: every exchange file resolves through the file-trace killer query."
  exit 0
}

main "$@"
