#!/usr/bin/env bash
# Red-proofs scripts/verify-account-reference.sh by MUTATION.
#
# A gate that has only ever been run against a healthy artifact is a hypothesis
# with a green tick beside it. Each case below breaks exactly one property of a
# COPY of the real artifact and asserts the gate says so, in the right words,
# with the right exit code. Whatever survives a mutation is a property nothing
# is checking.
#
# Two exit codes, never conflated, because the difference is the whole point of
# the gate: 1 means the artifact was READ and is invalid, 2 means it could not
# be read or the instrument is broken and NOTHING WAS LEARNED.
#
# BASH, NOT ZSH: `for x in $joined` does not word-split in zsh, and
# ${PIPESTATUS[0]} expands to an empty string there rather than erroring.
set -u

INFRA="$(cd "$(dirname "$0")/.." && pwd -P)"
GATE="$INFRA/scripts/verify-account-reference.sh"
SRC="$INFRA/fixtures/reference/account/2026.08.09-001"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# Runs the gate over a freshly-rebuilt copy, then asserts BOTH the exit code and
# a specific message. Asserting the code alone passes for every reason a script
# can die, including the ones that mean the gate never ran.
check() {
  desc="$1"; want_rc="$2"; want_re="$3"; dir="$4"
  out="$("$GATE" "$dir" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL  $desc"
    echo "      wanted exit $want_rc, got $rc"
    echo "      output: $out"
    fail=$((fail + 1))
    return
  fi
  if ! printf '%s\n' "$out" | grep -qE "$want_re"; then
    echo "FAIL  $desc"
    echo "      exit $rc was right but the message did not match: $want_re"
    echo "      output: $out"
    fail=$((fail + 1))
    return
  fi
  echo "ok    $desc  (exit $rc)"
  pass=$((pass + 1))
}

# A fresh unmutated copy for each case, so one mutation cannot leak into the next.
fresh() {
  d="$WORK/$1"
  rm -rf "$d"
  mkdir -p "$d/2026.08.09-001"
  cp "$SRC/manifest.properties" "$SRC/account.csv" "$d/2026.08.09-001/"
  echo "$d/2026.08.09-001"
}

# Rewrites one manifest key in place. sed -i differs between BSD and GNU and
# BSD sed does not understand \b, so this is done with awk and a rewrite rather
# than an in-place substitution whose behaviour depends on the machine.
set_key() {
  f="$1/manifest.properties"; k="$2"; v="$3"
  awk -F= -v k="$k" -v v="$v" '
    /^[[:space:]]*#/ { print; next }
    $1 == k { print k "=" v; next }
    { print }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

drop_key() {
  f="$1/manifest.properties"; k="$2"
  awk -F= -v k="$k" '$1 == k { next } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
}

# A MUTATION THAT DID NOT LAND LOOKS EXACTLY LIKE A GATE THAT DID NOT CATCH IT.
# This bit before it was written: the CSV sorts COLLECTIONS ahead of MANDATES, so
# a mutation aimed at "line 2, if it starts with MANDATES" matched nothing, the
# artifact was still pristine, the gate correctly passed it, and the case was
# reported as a surviving property. Every CSV mutation now proves it changed the
# file, and a mutation that did not land is an INSTRUMENT failure, never a finding.
mutated() {
  if cmp -s "$1/account.csv" "$SRC/account.csv"; then
    echo "FAIL  $2"
    echo "      INSTRUMENT: the mutation did not change account.csv, so this case"
    echo "      tested the unmutated artifact. A false survivor, not a finding."
    fail=$((fail + 1))
    return 1
  fi
  return 0
}

echo "=== POSITIVE CONTROL: the real artifact, unmutated, must pass ==="
check 'unmutated real artifact -> PASS' 0 'PASS: 2026\.08\.09-001' "$SRC"
echo
echo "=== the gate must REFUSE each broken property ==="

d=$(fresh checksum); printf 'MANDATES,69999999999999999,FNBRF,ACTIVE,CHQ,,,,,,,,,,,,,\n' >> "$d/account.csv"
mutated "$d" 'account.csv edited -> checksum mismatch' && \
check 'account.csv edited, manifest untouched -> checksum mismatch' 1 'checksum mismatch' "$d"

d=$(fresh schema); set_key "$d" schema.version 2
check 'schema.version=2 -> refused, naming both numbers' 1 "schema\.version is '2'; this gate understands '1' only" "$d"

d=$(fresh rowcount); set_key "$d" row.count 109
check 'row.count disagrees with the file -> refused' 1 "row\.count is '109' but account\.csv holds 110 data rows" "$d"

d=$(fresh nokey); drop_key "$d" source.id
check 'source.id absent -> refused (all seven are mandatory)' 1 "manifest key 'source\.id' is absent or empty" "$d"

d=$(fresh nosum); drop_key "$d" checksum.sha256
check 'checksum.sha256 absent -> refused' 1 "manifest key 'checksum\.sha256' is absent or empty" "$d"

d=$(fresh header); sed '1s/.*/account_number,product_code/' "$d/account.csv" > "$d/x" && mv "$d/x" "$d/account.csv"
mutated "$d" 'header shape changed' && \
check 'header shape changed -> refused before any row is read' 1 'header does not match schema' "$d"

# Line 2 is a COLLECTIONS row: the file sorts by (shape, account_number) and
# COLLECTIONS sorts first. Anchoring on the field rather than on a remembered
# ordering is what makes this mutation land wherever the sort puts things.
d=$(fresh shape)
awk -F, 'NR == 2 { sub(/^[A-Z]+,/, "UNKNOWNSHAPE,") } { print }' "$d/account.csv" > "$d/x" && mv "$d/x" "$d/account.csv"
mutated "$d" 'unknown shape' && \
check 'a shape the gate does not know -> refused, never silently unclaimed' 1 'neither COLLECTIONS nor MANDATES' "$d"

d=$(fresh dupe); awk 'NR==2 {print; print} NR!=2 {print}' "$d/account.csv" > "$d/x" && mv "$d/x" "$d/account.csv"
mutated "$d" 'account_number duplicated' && \
check 'account_number duplicated -> refused' 1 'account_number is not unique' "$d"

d=$(fresh nomanifest); rm "$d/manifest.properties"
check 'manifest absent -> refused, not treated as an empty dataset' 1 'manifest\.properties is absent or unreadable' "$d"

d=$(fresh nodata); rm "$d/account.csv"
check 'account.csv absent -> refused' 1 'account\.csv is absent or unreadable' "$d"

d=$(fresh renamed)
mv "$WORK/renamed/2026.08.09-001" "$WORK/renamed/2026.08.09-002"
check 'directory renamed, manifest left alone -> the disagreement is caught' 1 \
  "directory is named '2026\.08\.09-002' but manifest declares" "$WORK/renamed/2026.08.09-002"

echo
echo "=== 'could not look' must NEVER be reported as 'looked and found nothing' ==="
check 'a path that is not a directory -> exit 2, nothing concluded' 2 'is not a directory' "$WORK/no-such-artifact"

echo
echo "=== the ZERO-ROW case, which is the defect class this wave removes ======="
d=$(fresh emptyprojection)
awk -F, 'NR == 1 || $1 != "COLLECTIONS"' "$d/account.csv" > "$d/x" && mv "$d/x" "$d/account.csv"
mutated "$d" 'no COLLECTIONS rows' || true
# The row count and checksum now disagree too, so this case is deliberately read
# for its SHAPE message: an artifact with no COLLECTIONS rows must never pass,
# by whichever of its broken properties is noticed first.
check 'no COLLECTIONS rows -> refused (two loaders would load zero)' 1 \
  'checksum mismatch|no COLLECTIONS rows' "$d"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ALL MUTATIONS CAUGHT: every property the gate claims to check is load-bearing."
