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
# Corrected 2026-08-08: this listed a `platform-test` that does not exist and
# omitted `platform-model` and `platform-persistence` that do. The constant is
# not read by the loop below, which is exactly why it was wrong and stayed wrong:
# a value nothing executes is a comment wearing the costume of a check.
ALLOWED_platform="platform-batch platform-copybook platform-files platform-model platform-persistence"
# SCRUM-107 adds `acs`, the account reference service. Like hcs and rpt it is
# cross-family and appears on no diagram sheet, which is why it is declared here:
# the sheets are the specification for the three FAMILIES, and a shared context
# that no sheet shows would otherwise read as drift forever.
ALLOWED_shared="acs hcs rpt"

[ -d "$ROOT" ] || { echo "FAIL: \$DCRE_ROOT '$ROOT' is not a directory."; \
                    echo "      The tree was not read, so no conclusion is drawn."; exit 2; }

# A NAME IS NOT A SERVICE. Until 2026-08-08 this gate tested `[ -d ]` only, so a
# directory that merely looked like a service satisfied it. It printed
# "shared 3 present, conformant" while shared/acs had no .git at all: from inside
# it `git rev-parse --show-toplevel` returned $HOME, because the home repo's
# ignore rules were swallowing the whole tree. Every service here is its OWN
# repository, so a service without one is unpushable, unreviewable and invisible
# to every other engineer, which is precisely the isolation this split exists to
# provide. Four independent audit lenses also missed it, because they all asked
# "is the directory there" rather than "is it the thing".
#
# Echoes a defect string, or nothing. Empty means healthy.
# ASK GIT FIRST, not the filesystem. An earlier version tested `[ ! -e .git ]`
# up front and returned "no-git" immediately, which made the ancestor-ownership
# arm unreachable for the ONLY case that has actually occurred: shared/acs had no
# .git of its own AND resolved to $HOME, because the home repo was swallowing the
# tree. "no-git" says the directory is not a repo; "owned-by-/Users/sean" says
# which repo has captured it, and only the second sentence tells you what to fix.
repo_defect() {
  d="${1%/}"
  # A .git that belongs to an ANCESTOR is the same defect wearing a disguise:
  # the directory is tracked by some outer repo rather than being its own.
  #
  # Compare PHYSICAL paths on both sides. `git rev-parse --show-toplevel` always
  # resolves symlinks, so comparing it against a logical path reports every
  # service as ancestor-owned the moment any parent is a symlink. On macOS /tmp
  # is a symlink to /private/tmp, which made a fully healthy fixture fail all 36
  # checks on 2026-08-08. The real tree passed only because it happens to live
  # somewhere with no symlink in the path, which is luck, not correctness.
  phys=$(cd "$d" 2>/dev/null && pwd -P)
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$phys" ]; then
    echo " $(basename "$d"):unreadable-path"
  elif [ -z "$top" ]; then
    # git could not resolve a toplevel at all: no repo anywhere up the tree.
    echo " $(basename "$d"):no-git"
  elif [ "$top" != "$phys" ]; then
    echo " $(basename "$d"):owned-by-$top"
  elif ! git -C "$d" remote get-url origin >/dev/null 2>&1; then
    echo " $(basename "$d"):no-origin"
  fi
}

rc=0
not_a_repo=""
for fam in collections payments mandates; do
  eval "req=\$REQ_$fam"
  [ -d "$ROOT/$fam" ] || { echo "FAIL: family directory '$fam' is absent entirely."; rc=1; continue; }

  present=""
  for d in "$ROOT/$fam"/*/; do
    [ -d "$d" ] || continue
    present="$present $(basename "$d")"
    not_a_repo="$not_a_repo$(repo_defect "$d")"
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

# The non-service directories are checked too, against the same three-direction
# rule. Until 2026-08-08 these two constants were declared and never read: the
# loop above only walked the three families. The dead constant then drifted
# unnoticed, naming a `platform-test` that does not exist and omitting
# `platform-model` and `platform-persistence` that do, which is exactly what a
# value nothing executes does. Reading them here is what makes them a check.
for grp in platform shared; do
  eval "allowed=\$ALLOWED_$grp"
  [ -d "$ROOT/$grp" ] || { echo "FAIL: '$grp' directory is absent entirely."; rc=1; continue; }

  present=""
  for d in "$ROOT/$grp"/*/; do
    [ -d "$d" ] || continue
    present="$present $(basename "$d")"
    not_a_repo="$not_a_repo$(repo_defect "$d")"
  done
  present="$present "
  [ "$present" = " " ] && { echo "FAIL: '$grp' contains no directories at all."; \
                            echo "      Treating as unreadable, not as 'all absent'."; exit 2; }

  missing=""
  for s in $allowed; do
    case "$present" in *" $s "*) ;; *) missing="$missing $s" ;; esac
  done

  extra=""
  for p in $present; do
    case " $allowed " in *" $p "*) continue ;; esac
    extra="$extra $p"
  done

  n_allowed=$(echo "$allowed" | wc -w | tr -d ' ')
  n_have=$(echo "$present" | wc -w | tr -d ' ')
  printf "%-12s %s expected, %s present" "$grp" "$n_allowed" "$n_have"
  [ -n "$missing" ] && printf ", ABSENT:%s" "$missing"
  [ -n "$extra" ]   && printf ", UNDECLARED:%s" "$extra"
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

if [ -n "$not_a_repo" ]; then
  echo "FAIL: directories present by NAME but not standalone git repositories:$not_a_repo"
  echo "      no-git        = no .git at all, so it cannot be pushed or reviewed"
  echo "      owned-by-PATH = tracked by an ANCESTOR repo, not its own"
  echo "      git-unreadable= .git exists but git could not read it"
  echo "      no-origin     = a repo with no remote, so it exists only on this machine"
  echo "      A name is not a service. This gate passed a directory with no .git"
  echo "      on 2026-08-08 because it tested only that the folder existed."
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: all three families match the diagrams by name, and every service is"
  echo "      its own git repository with a remote."
else
  echo "FAIL: topology deviates from the diagrams. This is an imminent failure,"
  echo "      not a nitpick. Fix the gaps, then re-run. If they are still not"
  echo "      addressed after that, STOP and report: an unresolved topology"
  echo "      mismatch is a design question for the owner, not one to converge"
  echo "      on by trial."
fi
exit "$rc"
