#!/usr/bin/env bash
# Red-proofs scripts/materialise-account-reference.sh by MUTATION.
#
# The script under test is a DEPLOY STEP, so the failure it exists to remove is
# a step that silently does nothing: the `account` table was empty in every
# deployed environment and three families reported FAIL_ACCOUNT_NOT_FOUND for
# months as a data-quality problem. A staging step that fails quietly recreates
# exactly that, so every case below breaks one property and asserts the script
# REFUSES, in the right words, with the right exit code, and leaves the
# destination in a state somebody can reason about.
#
# EVERY CASE ASSERTS AN EXACT EXIT CODE AND A SPECIFIC MESSAGE. A non-zero
# assertion passes for every reason a process can die, including the ones that
# mean the script never ran: this project has already paid for eleven vacuous
# checks in one file whose default arm was the passing one. Here the passing
# conditions are enumerated and EVERYTHING else, INCLUDING EMPTY OUTPUT, is a
# failure.
#
# Two exit codes, never conflated, because that distinction is inherited from
# verify-account-reference.sh and is the whole point of the gate: 1 means the
# artifact was READ and is invalid, 2 means it could not be read, could not be
# resolved, or the copy failed, and NOTHING WAS LEARNED.
#
# BASH, NOT ZSH: `for x in $joined` does not word-split in zsh, and
# ${PIPESTATUS[0]} expands to an empty string there rather than erroring.
#
# Everything happens in a temp directory. The real fixtures under
# fixtures/reference/account/ are READ and never written, and the real
# exchange/ tree is never touched: a test that mutates the artifact it is
# testing against would be testing yesterday's artifact from then on.
set -u

INFRA="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Overridable ONLY so this suite can be red-proofed against a deliberately
# mutated copy of the script. A suite that has never been shown to fail is a
# hypothesis with a green tick beside it, and the mutant must live in a tree
# shaped like this one so it resolves the same gate and the same fixtures.
SUT="${DCRE_MATERIALISE_SUT:-$INFRA/scripts/materialise-account-reference.sh}"
SRC_FIXTURE="$INFRA/fixtures/reference/account/2026.08.09-001"
VERSION="2026.08.09-001"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

note_pass() { echo "ok    $1"; pass=$((pass + 1)); }
note_fail() { echo "FAIL  $1"; shift; while [ "$#" -gt 0 ]; do echo "      $1"; shift; done; fail=$((fail + 1)); }

# A fresh case directory: an untouched copy of the real artifact as the SOURCE,
# and an empty exchange root as the DESTINATION. Rebuilt per case so one
# mutation cannot leak into the next.
fresh() {
  local d="$WORK/$1"
  rm -rf "$d"
  mkdir -p "$d/src/$VERSION" "$d/ex"
  cp "$SRC_FIXTURE/manifest.properties" "$SRC_FIXTURE/account.csv" "$d/src/$VERSION/"
  printf '%s' "$d"
}

# Runs the script under test with the case's roots, capturing BOTH the output and
# the status. Never a pipeline: `cmd | grep` would put grep's status where the
# script's belongs.
OUT=""
RC=0
run_sut() {
  local case_dir="$1"; shift
  OUT=""
  RC=0
  OUT=$(DCRE_REFERENCE_SOURCE_ROOT="$case_dir/src" \
        DCRE_EXCHANGE_HOST_ROOT="$case_dir/ex" \
        bash "$SUT" "$@" 2>&1) || RC=$?
}

# THE PASSING CONDITIONS ARE ENUMERATED. Three of them, all required:
#   the exit code is exactly the one named,
#   the output matches the message named,
#   the output is NON-EMPTY.
# Anything else, including a script that printed nothing at all, is a failure.
# The empty case matters: a script killed before it wrote a byte and a script
# that ran silently are indistinguishable by exit code alone, and one of those
# means the test never happened.
check() {
  local desc="$1" want_rc="$2" want_re="$3" case_dir="$4"; shift 4
  run_sut "$case_dir" "$@"
  if [ -z "$OUT" ]; then
    note_fail "$desc" "the script produced NO OUTPUT AT ALL (exit $RC)." \
      "An empty result is not a pass: it is the shape of a run that never happened."
    return 1
  fi
  if [ "$RC" -ne "$want_rc" ]; then
    note_fail "$desc" "wanted exit $want_rc, got $RC" "output: $OUT"
    return 1
  fi
  if ! printf '%s\n' "$OUT" | grep -qE "$want_re"; then
    note_fail "$desc" "exit $RC was right but the message did not match: $want_re" \
      "output: $OUT"
    return 1
  fi
  note_pass "$desc  (exit $RC)"
  return 0
}

# A MUTATION THAT DID NOT LAND LOOKS EXACTLY LIKE A SCRIPT THAT DID NOT CATCH IT.
# Every corruption below proves it changed the bytes before the case is believed;
# a mutation that did not land is an INSTRUMENT failure, never a finding.
mutated() {
  if cmp -s "$1" "$2"; then
    note_fail "$3" "INSTRUMENT: the mutation did not change '$1', so this case" \
      "tested an unmutated artifact. A false survivor, not a finding."
    return 1
  fi
  return 0
}

# Asserts the staged copy is byte-identical to the source artifact. This is the
# assertion the whole script exists to make true, so it is checked directly
# rather than inferred from exit 0.
assert_staged_identical() {
  local case_dir="$1" desc="$2"
  local dest="$case_dir/ex/reference/account/$VERSION"
  local src="$case_dir/src/$VERSION"
  if [ ! -d "$dest" ]; then
    note_fail "$desc" "nothing was staged: '$dest' does not exist."
    return 1
  fi
  local f
  for f in account.csv manifest.properties; do
    if [ ! -f "$dest/$f" ]; then
      note_fail "$desc" "'$dest/$f' is absent: the artifact landed incomplete."
      return 1
    fi
    if ! cmp -s "$src/$f" "$dest/$f"; then
      note_fail "$desc" "'$f' at the destination differs from the source artifact."
      return 1
    fi
  done
  # The checksum, recomputed over the STAGED bytes and compared to the manifest,
  # rather than trusting cmp alone. This is what a loader will do.
  local declared actual
  declared=$(awk -F= '$1 == "checksum.sha256" { print $2; exit }' "$dest/manifest.properties")
  actual=$(shasum -a 256 "$dest/account.csv")
  actual="${actual%% *}"
  if [ -z "$declared" ] || [ -z "$actual" ]; then
    note_fail "$desc" "could not compute a checksum pair (declared='${declared:-<empty>}'," \
      "actual='${actual:-<empty>}'). The instrument failed; nothing is concluded."
    return 1
  fi
  if [ "$declared" != "$actual" ]; then
    note_fail "$desc" "staged checksum mismatch: manifest=$declared actual=$actual"
    return 1
  fi
  note_pass "$desc  (checksum verified over the staged bytes: $actual)"
  return 0
}

assert_nothing_staged() {
  local case_dir="$1" desc="$2"
  local dest="$case_dir/ex/reference/account/$VERSION"
  if [ -e "$dest" ]; then
    note_fail "$desc" "'$dest' EXISTS. A refusal that still publishes is worse than" \
      "no gate at all: the loaders would read an artifact nothing vouched for."
    return 1
  fi
  # And no staging or superseded leftovers either: a half-copy left lying beside
  # the real path is the next reader's confusion.
  local leftovers
  leftovers=$(find "$case_dir/ex" -maxdepth 4 -name '.materialise-*' 2>/dev/null)
  if [ -n "$leftovers" ]; then
    note_fail "$desc" "staging leftovers survived the refusal:" "$leftovers"
    return 1
  fi
  note_pass "$desc"
  return 0
}

echo "=== POSITIVE CONTROL: the harness itself ================================="
# Before any absence is asserted below, prove the instrument can see a presence.
# The whole suite reads "did it stage / did it refuse to stage", and a harness
# whose paths are wrong reports every case as a refusal and looks like a very
# strict script.
d=$(fresh control)
if [ -f "$d/src/$VERSION/account.csv" ] && [ -d "$d/ex" ]; then
  note_pass "harness builds a case with a readable artifact and an empty exchange root"
else
  note_fail "harness setup" "the case directory is not what the suite assumes;" \
    "every 'refused' below would be this, not a finding."
fi

echo
echo "=== HAPPY PATH: a valid artifact is staged ==============================="
d=$(fresh happy)
check 'valid artifact -> staged, exit 0' 0 'STAGED: 2026\.08\.09-001' "$d"
assert_staged_identical "$d" 'the staged copy is byte-identical to the artifact'

# The destination path is not incidental: a stage pod mounts the exchange PVC at
# /exchange, so the copy MUST land under reference/account/<version> and nowhere
# else. A script that stages correct bytes to the wrong path is a script that
# does nothing.
if [ -f "$d/ex/reference/account/$VERSION/account.csv" ]; then
  note_pass 'the copy lands at exchange/reference/account/<version>, the path a pod reads'
else
  note_fail 'destination path' "account.csv is not at ex/reference/account/$VERSION/;" \
    "correct bytes at the wrong path are invisible to every loader."
fi

echo
echo "=== IDEMPOTENCE: re-running changes nothing ============================="
d=$(fresh idempotent)
check 'first run -> staged' 0 'STAGED: 2026\.08\.09-001' "$d"
before=$(shasum -a 256 "$d/ex/reference/account/$VERSION/account.csv")
before="${before%% *}"
check 'second run -> exit 0, recognised as already staged' 0 'nothing[[:space:]]*$|no-op|already' "$d"
after=$(shasum -a 256 "$d/ex/reference/account/$VERSION/account.csv")
after="${after%% *}"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
  note_pass "the second run left the same content ($after)"
else
  note_fail 'idempotent content' "content changed across an idempotent re-run:" \
    "before=${before:-<empty>} after=${after:-<empty>}"
fi
assert_staged_identical "$d" 'after two runs the staged copy still matches the artifact'

echo
echo "=== ABSENT: the artifact directory does not exist ======================="
# The message must NAME the directory. "the artifact is missing" without a path
# is a sentence an operator cannot act on, and making this deploy step legible is
# the entire reason it exists.
d=$(fresh absent)
rm -rf "$d/src/$VERSION"
mkdir -p "$d/src/2026.01.01-999"
check 'artifact directory absent -> refused, exit 2, NAMING the directory' 2 \
  "artifact directory '.*/src/2026\.08\.09-001' does not exist" "$d" --version "$VERSION"
assert_nothing_staged "$d" 'an absent artifact stages nothing'

# The empty-root case is different from the absent-version case and must not be
# conflated with it: nothing was read at all.
d=$(fresh emptyroot)
rm -rf "$d/src/$VERSION"
check 'no version directory at all -> refused, exit 2, unbuilt not empty' 2 \
  'no version directory under' "$d"
assert_nothing_staged "$d" 'an empty artifact root stages nothing'

d=$(fresh noroot)
rm -rf "$d/src"
check 'the artifact root itself is absent -> exit 2, nothing concluded' 2 \
  "artifact root '.*/src' is not a directory" "$d"

echo
echo "=== CORRUPT: the bytes changed and the checksum no longer holds =========="
d=$(fresh corrupt)
# One byte, in a data row, leaving row count and header intact so the ONLY broken
# property is the checksum. A mutation that breaks three things at once cannot
# tell you which one was noticed.
awk 'NR == 2 { sub(/ACTIVE/, "ACTIVF") } { print }' "$d/src/$VERSION/account.csv" > "$d/x" \
  && mv "$d/x" "$d/src/$VERSION/account.csv"
if mutated "$d/src/$VERSION/account.csv" "$SRC_FIXTURE/account.csv" 'corrupt artifact'; then
  check 'corrupt artifact -> refused, exit 1, NAMING the artifact' 1 \
    "REFUSED\(1\): the artifact '.*/src/2026\.08\.09-001' did not validate" "$d"
  assert_nothing_staged "$d" 'a corrupt artifact stages nothing'
fi

# The corruption must also be reported as a FINDING (exit 1, the artifact was
# read and is invalid), never as "could not be read" (exit 2). Those are
# different claims and only one of them is about the artifact.
d=$(fresh corrupt_not_unreadable)
awk 'NR == 2 { sub(/ACTIVE/, "ACTIVF") } { print }' "$d/src/$VERSION/account.csv" > "$d/x" \
  && mv "$d/x" "$d/src/$VERSION/account.csv"
if mutated "$d/src/$VERSION/account.csv" "$SRC_FIXTURE/account.csv" 'corrupt is a finding'; then
  run_sut "$d"
  if [ "$RC" -eq 1 ]; then
    note_pass 'a corrupt artifact is exit 1 (read and invalid), never exit 2 (unreadable)'
  else
    note_fail 'corrupt severity' "wanted exit 1, got $RC. A corrupt artifact was READ:" \
      "reporting it as 'nothing was learned' hides a real finding." "output: $OUT"
  fi
fi

echo
echo "=== a REFUSAL must not destroy the copy already on the PVC =============="
# The loaders read the staged copy. A failed re-materialisation that deletes the
# good copy first turns a bad new artifact into an outage for the old one.
d=$(fresh corrupt_after_good)
run_sut "$d"
if [ "$RC" -ne 0 ]; then
  note_fail 'preload for the destructive-refusal case' "the first, valid run exited $RC" "output: $OUT"
else
  awk 'NR == 2 { sub(/ACTIVE/, "ACTIVF") } { print }' "$d/src/$VERSION/account.csv" > "$d/x" \
    && mv "$d/x" "$d/src/$VERSION/account.csv"
  if mutated "$d/src/$VERSION/account.csv" "$SRC_FIXTURE/account.csv" 'corrupt after a good stage'; then
    check 'corrupt artifact after a good stage -> refused, exit 1' 1 \
      "REFUSED\(1\): the artifact '.*' did not validate" "$d"
    good=$(shasum -a 256 "$d/ex/reference/account/$VERSION/account.csv" 2>/dev/null)
    good="${good%% *}"
    if [ "$good" = "5831d612cbcce77f17f5f4ee50dd05cfed14bfc6ce72182649f4eccdb64e75a6" ]; then
      note_pass 'the previously staged, valid copy survived the refusal untouched'
    else
      note_fail 'refusal destroyed the good copy' \
        "the staged copy now checksums '${good:-<absent>}'," \
        "expected the original 5831d612...e75a6. A refusal must not take the" \
        "working artifact down with it."
    fi
  fi
fi

echo
echo "=== a STALE staged copy is replaced, not left in place =================="
# The other direction: the destination must never win over the artifact. A stale
# copy that survives is a second home for the fact, and nothing at read time says
# which one is current.
d=$(fresh stale)
mkdir -p "$d/ex/reference/account/$VERSION"
printf 'shape,account_number\nCOLLECTIONS,1\n' > "$d/ex/reference/account/$VERSION/account.csv"
printf 'dataset.version=%s\n' "$VERSION" > "$d/ex/reference/account/$VERSION/manifest.properties"
check 'a stale staged copy is replaced -> exit 0' 0 'STAGED: 2026\.08\.09-001' "$d"
assert_staged_identical "$d" 'the stale copy was replaced by the real artifact'

echo
echo "=== AMBIGUOUS VERSION: refuse to guess =================================="
# verify-account-reference.sh already refuses here, and this script copies that
# refusal rather than inventing a different one. Picking "the newest" or "the
# last alphabetically" would silently change what every verdict in three
# families is judged against.
d=$(fresh ambiguous)
cp -R "$d/src/$VERSION" "$d/src/2026.08.10-001"
check 'two version directories, no --version -> refused, exit 2' 2 \
  '2 version directories under' "$d"
assert_nothing_staged "$d" 'an ambiguous artifact set stages nothing'

# And the disambiguation works: the SAME set with --version given stages the
# named one. Without this the refusal above could be satisfied by a script that
# refuses unconditionally, which would pass the case and ship nothing.
d=$(fresh ambiguous_named)
cp -R "$d/src/$VERSION" "$d/src/2026.08.10-001"
check 'two version directories WITH --version -> stages the named one, exit 0' 0 \
  'STAGED: 2026\.08\.09-001' "$d" --version "$VERSION"
assert_staged_identical "$d" '--version staged exactly the version that was named'
if [ -e "$d/ex/reference/account/2026.08.10-001" ]; then
  note_fail 'version selection' "the unnamed version 2026.08.10-001 was staged too;" \
    "--version must select one artifact, not seed the whole set."
else
  note_pass 'the version that was NOT named was not staged'
fi

echo
echo "=== ARGUMENTS: an unrecognised flag is not ignored ======================="
# A silently ignored flag is how a --run-loaders typo becomes "the loaders ran".
d=$(fresh args)
check 'unrecognised argument -> refused, exit 2' 2 "unrecognised argument '--stage-it'" "$d" --stage-it
assert_nothing_staged "$d" 'an unrecognised argument stages nothing'

d=$(fresh emptyversion)
check '--version with an empty value -> refused, not treated as unset' 2 \
  'given an empty value' "$d" --version=

echo
echo "=== the DEFAULT PATH must not touch a cluster ============================"
# The loader invocation is unverified against a cluster and is gated behind
# --run-loaders. If it ever leaks into the default path, a cutover starts making
# calls nobody has tested. Proven by putting a kubectl on PATH that fails loudly
# if it is called at all.
d=$(fresh nokubectl)
STUB="$WORK/stub-nokubectl"
mkdir -p "$STUB"
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
echo "STUB: kubectl was invoked on the default path. It must not be." >&2
exit 77
STUBEOF
chmod +x "$STUB/kubectl"
OUT=$(PATH="$STUB:$PATH" DCRE_REFERENCE_SOURCE_ROOT="$d/src" DCRE_EXCHANGE_HOST_ROOT="$d/ex" \
      bash "$SUT" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q 'STUB: kubectl was invoked'; then
  note_pass 'the default path stages without invoking kubectl once'
else
  note_fail 'default path touched the cluster' "exit=$RC" "output: $OUT"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ALL MUTATIONS CAUGHT: every property this deploy step claims is load-bearing."
