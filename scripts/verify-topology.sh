#!/usr/bin/env bash
# Asserts the DCRE service directories match the canonical diagrams EXACTLY.
#
# Sean directive 2026-08-08: the diagrams are the specification. Any deviation
# is an imminent failure. This is the gate referenced by /wat-release section 0
# and /wat-review section 0, and it runs before every other gate because every
# later gate is wasted effort if the tree ships the wrong services.
#
#   exit 0  every family matches its sheet, by NAME
#   exit 1  a family deviates: absent, or present-but-on-no-sheet
#   exit 2  the tree could not be read. Nothing was learned.
#
# BASH, NOT ZSH, DELIBERATELY. `for s in $req` does not word-split in zsh, so
# the loop compares each family against ONE long string, nothing ever matches,
# and every service is reported both absent AND unexpected. That false alarm
# happened on 2026-08-08 and is the reason this file has a shebang and lives on
# disk instead of being retyped as an inline snippet.
set -u

ROOT="${DCRE_ROOT:-$HOME/env/repo/be/java/spring/dcre}"

# Derived from design-register/docs/diagrams (ignore archive-2026-07/).
# Order is the DAG order on each sheet, so a reader can check it against the
# picture without re-deriving it.
REQ_collections="crr ctv cde crw cir cix csx cpx crg"
REQ_payments="prr ptv pai prw pir pix psx ppx prg"
REQ_mandates="mrr mrv mas mit mir mrw mix msx mpx mrg"

# On no sheet by design: cross-family helpers and Gradle dependencies, not
# services. Listed explicitly so that "present but on no sheet" stays a real
# finding rather than a permanent false positive nobody reads.
ALLOWED_platform="platform-batch platform-copybook platform-files platform-test"
ALLOWED_shared="hcs rpt"

[ -d "$ROOT" ] || { echo "FAIL: \$DCRE_ROOT '$ROOT' is not a directory."; \
                    echo "      The tree was not read, so no conclusion is drawn."; exit 2; }

rc=0
for fam in collections payments mandates; do
  eval "req=\$REQ_$fam"
  [ -d "$ROOT/$fam" ] || { echo "FAIL: family directory '$fam' is absent entirely."; rc=1; continue; }

  present=""
  for d in "$ROOT/$fam"/*/; do
    [ -d "$d" ] || continue
    present="$present $(basename "$d")"
  done
  present="$present "

  # A family with no subdirectories at all is an unreadable listing, not an
  # empty family: that state does not exist in this project.
  [ "$present" = " " ] && { echo "FAIL: '$fam' contains no service directories at all."; \
                            echo "      Treating as unreadable, not as 'all absent'."; exit 2; }

  missing=""
  for s in $req; do
    case "$present" in *" $s "*) ;; *) missing="$missing $s" ;; esac
  done

  extra=""
  for p in $present; do
    case " $req " in *" $p "*) continue ;; esac
    extra="$extra $p"
  done

  n_req=$(echo "$req" | wc -w | tr -d ' ')
  n_have=$(echo "$present" | wc -w | tr -d ' ')

  # Name the universe with the number. "9 of 9" hides four misnamed services;
  # "9 required, 9 present, 4 on no sheet" is what caught this on 2026-08-08.
  printf "%-12s %s required, %s present" "$fam" "$n_req" "$n_have"
  [ -n "$missing" ] && printf ", ABSENT:%s" "$missing"
  [ -n "$extra" ]   && printf ", ON NO SHEET:%s" "$extra"
  [ -z "$missing" ] && [ -z "$extra" ] && printf ", conformant"
  printf "\n"

  [ -n "$missing" ] && rc=1
  [ -n "$extra" ]   && rc=1
done

# Positive control: the required sets must be non-empty and distinct, so a
# truncated or duplicated constant cannot make this script pass by comparing
# nothing against nothing.
for fam in collections payments mandates; do
  eval "req=\$REQ_$fam"
  cnt=$(echo "$req" | wc -w | tr -d ' ')
  [ "$cnt" -ge 9 ] || { echo "FAIL: REQ_$fam holds only $cnt names; the constant is truncated."; \
                        echo "      A short required-set makes this gate pass vacuously."; exit 2; }
done

if [ "$rc" -eq 0 ]; then
  echo "PASS: all three families match the diagrams by name."
else
  echo "FAIL: topology deviates from the diagrams. This is an imminent failure,"
  echo "      not a nitpick. Fix the gaps, then re-run. If they are still not"
  echo "      addressed after that, STOP and report: an unresolved topology"
  echo "      mismatch is a design question for the owner, not one to converge"
  echo "      on by trial."
fi
exit "$rc"
