#!/usr/bin/env bash
#
# THE COMMIT GATE: the tests this change touches, derived from the change.
#
# WHY NOT THE FORK SET. script/fork-tests.sh runs every test file the fork owns,
# and by 2026-10-24 that was 3,173 tests and over half an hour -- long enough
# that the default gate budget cut it off unfinished. A commit gate that long
# stops being run. So the operator ruled two tiers (2026-10-24): this one for a
# commit, minutes; the fork set for a deploy (`coherence gate --deploy`), which
# catches what this misses before production does. The cost was accepted in
# plain words: the branch can go red between deploys.
#
# DERIVED, NEVER A KEPT LIST -- and from the change, never from memory of it:
#   1. the change is every file differing from the branch's upstream: commits
#      not pushed, the working tree, and untracked files;
#   2. a changed test file runs;
#   3. a changed code file runs the tests named after it (user.rb ->
#      user_test.rb anywhere under test/, a script -> its _script_test.rb, a
#      view directory -> its controller's test), and the tests that name a
#      class it defines -- or, in config/danbooru_default_config.rb, a setting
#      the change touches -- unless that name is so widely used it chooses
#      nothing (TOO_WIDE), which is said by name;
#   4. a change to what EVERY test stands on -- the runtime, the schema, the
#      test helpers and factories, the application base classes -- cannot be
#      narrowed, so it runs the fork set instead;
#   5. a fixed smoke set always runs, and a smoke file that is gone FAILS:
#      a smoke set that quietly shrinks is the confident green this prevents.
# A code file nothing maps to is printed by name. It is not tested here; the
# deploy gate tests it.
#
#   bash script/change-tests.sh          derive and run
#   bash script/change-tests.sh --list   the derivation, without the run
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

LIST_ONLY=""
[ "${1:-}" = "--list" ] && LIST_ONLY=1

# The base controller, the retired sections and the error pages: 92 test
# seconds measured 2026-10-24 (~/.local/state/chanbooru/fork-test-timing.tsv). Not
# anonymous_default_deny_test.rb, the widest net and 924 of them on its own;
# the deploy gate runs it.
SMOKE=(
  test/functional/application_controller_test.rb
  test/functional/fourier_retired_sections_test.rb
  test/functional/error_page_test.rb
)
# A class named in more test files than this is too common to choose by.
TOO_WIDE=25

BASE="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || {
  echo "FAIL: the branch $(git branch --show-current) has no upstream, so the change cannot be derived."
  echo "fix:  git branch --set-upstream-to=origin/chanbooru"
  exit 2
}

MISSING=()
for f in "${SMOKE[@]}"; do [ -f "$f" ] || MISSING+=("$f"); done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "FAIL: the smoke set names test files that are gone:"
  printf '  %s\n' "${MISSING[@]}"
  echo "fix:  replace each with the test that now covers what it did, in SMOKE in $0"
  exit 2
fi

mapfile -t CHANGED < <({
  git diff --name-only "$BASE"...HEAD
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
} | sort -u)

# Rule 4: what every test stands on. Matched as path prefixes.
# shellcheck source=script/chanbooru-runtime-files.sh
source script/chanbooru-runtime-files.sh
EVERYTHING=("${RUNTIME_FILES[@]}" db/ test/test_helper.rb test/test_helpers/
  test/factories/ test/fourier_database_guard.rb config/application.rb
  config/environments/ config/initializers/ app/models/application_record.rb
  app/controllers/application_controller.rb app/policies/application_policy.rb
  app/components/application_component.rb app/views/layouts/)
for f in "${CHANGED[@]}"; do
  for p in "${EVERYTHING[@]}"; do
    if [[ "$f" == "$p" || ( "$p" == */ && "$f" == "$p"* ) || "$f" == "$p"/* ]]; then
      echo "$f is under what every test stands on ($p), so this change cannot be narrowed: running the fork set."
      [ -n "$LIST_ONLY" ] && exec bash script/fork-tests.sh --list
      exec bash script/fork-tests.sh
    fi
  done
done

# Every test file by basename, once: the map rule 3 looks names up in.
declare -A BY_NAME=()
while IFS= read -r t; do BY_NAME[${t##*/}]+="$t "; done \
  < <(git ls-files -- ':(glob)test/**/*_test.rb'; git ls-files --others --exclude-standard -- ':(glob)test/**/*_test.rb')

TESTS=() UNMAPPED=() WIDE=()
add_named() { local n; for n in "$@"; do [ -n "${BY_NAME[$n]:-}" ] && TESTS+=(${BY_NAME[$n]}); done; }
# The tests that name a word, unless so many do that the word chooses nothing.
add_naming() {
  local src="$1" w hits; shift
  for w in "$@"; do
    mapfile -t hits < <(git grep -lw -- "$w" -- ':(glob)test/**/*_test.rb')
    if [ "${#hits[@]}" -gt "$TOO_WIDE" ]; then
      WIDE+=("$w (in $src) is named in ${#hits[@]} test files")
    else
      TESTS+=("${hits[@]}")
    fi
  done
}
for f in "${CHANGED[@]}"; do
  case "$f" in
    test/*_test.rb) [ -f "$f" ] && TESTS+=("$f"); continue ;;
    *.md|docs/*|LICENSE*|.vscode/*) continue ;;
  esac
  before=${#TESTS[@]}
  base="${f##*/}" stem="${base%%.*}"
  stem="${stem//-/_}"
  case "$f" in
    app/*|lib/*|script/*|bin/*) add_named "${stem}_test.rb" "${stem}_script_test.rb" ;;
  esac
  if [[ "$f" == app/views/* ]]; then
    dir="${f#app/views/}" dir="${dir%/*}"
    add_named "${dir##*/}_controller_test.rb"
  fi
  if [[ "$f" == *.rb && -f "$f" ]]; then
    mapfile -t words < <(grep -oP '^\s*(class|module)\s+\K[A-Z][A-Za-z0-9_:]*' "$f" | sed 's/.*:://' | sort -u)
    add_naming "$f" "${words[@]}"
  fi
  # The site's settings are one file of methods, and the fork changes it more
  # than any other config: the settings the change touches are the names.
  if [[ "$f" == config/danbooru_default_config.rb ]]; then
    mapfile -t words < <(git diff "$BASE" -- "$f" | grep -oP '^[+-]\s*def \K\w+' | sort -u)
    add_naming "$f" "${words[@]}"
  fi
  if [ "${#TESTS[@]}" -eq "$before" ]; then
    UNMAPPED+=("$f")
  fi
done

mapfile -t FOR_CHANGE < <(printf '%s\n' "${TESTS[@]}" | grep . | sort -u)
mapfile -t RUN < <(printf '%s\n' "${FOR_CHANGE[@]}" "${SMOKE[@]}" | grep . | sort -u)
for t in "${RUN[@]}"; do [ -f "$t" ] || { echo "FAIL: derived $t, which does not exist."; exit 2; }; done
# Unreachable while the smoke set stands, and kept for the day it does not.
if [ "${#RUN[@]}" -eq 0 ]; then
  echo "FAIL: derived zero test files. Refusing to report a pass on nothing."
  exit 2
fi

echo "the change: ${#CHANGED[@]} file(s) differ from $BASE"
echo "running ${#RUN[@]} test file(s): ${#FOR_CHANGE[@]} for the change, and the ${#SMOKE[@]} of the smoke set"
printf '  %s\n' "${RUN[@]}"
if [ "${#WIDE[@]}" -gt 0 ]; then
  echo "too widely named to choose tests by (over $TOO_WIDE files each):"
  printf '  %s\n' "${WIDE[@]}"
fi
if [ "${#UNMAPPED[@]}" -gt 0 ]; then
  echo "changed, and no test maps to them -- the deploy gate (coherence gate --deploy) tests these:"
  printf '  %s\n' "${UNMAPPED[@]}"
fi
echo

[ -n "$LIST_ONLY" ] && exit 0
exec bash script/run-tests.sh "${RUN[@]}"
