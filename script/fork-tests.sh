#!/usr/bin/env bash
#
# Run the tests this FORK owns -- the ones that cover code we changed.
#
# WHY NOT THE WHOLE SUITE. `bin/rails test` is 6,368 tests and 32 minutes, and
# it cannot be green on this machine: 127 of its failures are upstream
# source-extractor tests that fetch live third-party sites (VK, Reddit, Fanbox,
# Skeb, ArcaLive...) and fail without credentials or when those sites change.
# A gate that is always red is a gate that gets ignored, which costs the same as
# no gate plus half an hour. Measured 2026-08-30: 115 failures, 20 errors, 475
# skips, and ZERO of them in fork-owned tests.
#
# The list is DERIVED, not maintained. A hand-written manifest goes stale the
# first time somebody adds a test and forgets -- and it already had: it named
# matrix_signin_frameability_test.rb, deleted weeks ago. `upstream/master...HEAD`
# is relative to the merge base, so upstream advancing does not change it, and
# it picks up upstream tests we MODIFIED as well as ones we added.
#
# The full suite still matters before a deploy or an upstream merge. It is just
# not the commit gate.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse --verify --quiet upstream/master >/dev/null; then
  echo "FAIL: no upstream/master ref, so the fork's own tests cannot be derived."
  echo "fix:  git remote add upstream https://github.com/danbooru/danbooru.git && git fetch upstream"
  exit 2
fi

mapfile -t FILES < <(git diff --name-only upstream/master...HEAD -- 'test/' | grep '_test\.rb$' || true)

# An empty list must never run zero tests and report success. That is the exact
# shape of the confident green this whole gate exists to prevent.
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "FAIL: derived zero fork-owned test files. Refusing to report a pass on nothing."
  echo "fix:  check that upstream/master is fetched and the merge base is sane:"
  echo "      git merge-base upstream/master HEAD"
  exit 2
fi

# Files can be deleted on this branch while still appearing in the diff.
EXISTING=()
for f in "${FILES[@]}"; do [ -f "$f" ] && EXISTING+=("$f"); done
if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "FAIL: every derived test file is missing from the worktree."
  exit 2
fi

echo "running ${#EXISTING[@]} fork-owned test file(s) of ${#FILES[@]} derived"
printf '  %s\n' "${EXISTING[@]}"
echo

WORKERS="$(nproc --ignore=1)"
exec docker compose -f docker-compose.dev.yaml exec -T \
  -e RAILS_ENV=test -e PARALLEL_WORKERS="$WORKERS" \
  danbooru bin/rails test "${EXISTING[@]}"
