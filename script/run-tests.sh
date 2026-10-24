#!/usr/bin/env bash
#
# Run the named test files in the devbooru stack. The one runner both gates
# share: script/change-tests.sh (the commit gate) and script/fork-tests.sh
# (the deploy gate) each DERIVE a list and hand it here.
#
#   bash script/run-tests.sh <test file>...
#
# TEST_TIMING=<path> also writes each test file's time to <path>, slowest
# first, as "<seconds>\t<tests>\t<file>" -- so every full run measures which
# files the budget goes to. Seconds are summed over the file's tests, which
# run in parallel, so they add up to more than the wall clock.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "$#" -eq 0 ]; then
  echo "FAIL: run-tests.sh was given no test files. Refusing to report a pass on nothing."
  echo "fix:  run a gate (script/change-tests.sh or script/fork-tests.sh), which derives the list"
  exit 2
fi

# THE DEV IMAGE MUST HAVE HEAD'S RUNTIME. The tests run in the dev image while
# production runs an image built from HEAD's Dockerfile and gems, so a dev
# image built from another runtime tests code against the wrong Ruby, vips or
# gems -- on 2026-10-04 vesper's was four weeks old. Said loudly here, with the
# rebuild, rather than discovered after a deploy.
# shellcheck source=script/chanbooru-runtime-files.sh
source script/chanbooru-runtime-files.sh
DEV_IMAGE="${DANBOORU_DEV_IMAGE:-$(sed -n 's/^DANBOORU_DEV_IMAGE=//p' .env)}"
DEV_REV="$(docker image inspect "$DEV_IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^DOCKER_IMAGE_REVISION=//p')"
if [[ -z "$DEV_REV" ]] || ! git cat-file -e "$DEV_REV^{commit}" 2>/dev/null; then
  echo "WARNING: the dev image $DEV_IMAGE names no revision this checkout knows, so its runtime cannot be compared with HEAD's."
  echo "fix:     TARGETS=development bin/build-docker-image danbooru, then bin/dev up -d"
  echo
elif STALE="$(git diff --name-only "$DEV_REV" HEAD -- "${RUNTIME_FILES[@]}")" && [[ -n "$STALE" ]]; then
  echo "WARNING: the dev image $DEV_IMAGE was built from ${DEV_REV:0:12}; HEAD has changed its runtime since:"
  sed 's/^/           /' <<< "$STALE"
  echo "         These tests run against the old runtime, not the one production will run."
  echo "fix:     TARGETS=development bin/build-docker-image danbooru, then bin/dev up -d"
  echo
fi

# WORKERS=2 for a light run. vesper is the operator's workstation, and a run
# at every core made it unusable (2026-10-04). `nice` on this script does not
# reach the tests -- they run inside the container -- so the light run lowers
# their priority there too.
WORKERS="${WORKERS:-$(nproc --ignore=1)}"
LIGHT=()
[ -n "${LIGHT_RUN:-}" ] && LIGHT=(nice -n 19)
RUN=(docker compose -f docker-compose.dev.yaml exec -T
     -e RAILS_ENV=test -e PARALLEL_WORKERS="$WORKERS"
     danbooru "${LIGHT[@]}" bin/rails test)
[ -z "${TEST_TIMING:-}" ] && exec "${RUN[@]}" "$@"

"${RUN[@]}" "$@"
rc=$?
# The JUnit reporter has already timed every class, one report per class, in
# the container's tmp; its <testsuite> line carries the name, count and time.
mkdir -p "$(dirname "$TEST_TIMING")"
docker compose -f docker-compose.dev.yaml exec -T danbooru \
    sh -c 'cat /danbooru/tmp/junit-test-results/*.xml' </dev/null 2>/dev/null \
  | gawk 'match($0, /<testsuite name="([^"]+)" filepath="([^"]+)".* tests="([0-9]+)".* time="([0-9.]+)"/, m) {
            printf "%.1f\t%d\t%s\n", m[4], m[3], m[2] }' \
  | sort -rn > "$TEST_TIMING"
if [ -s "$TEST_TIMING" ]; then
  echo "per-file timing: $TEST_TIMING, slowest first ($(head -1 "$TEST_TIMING" | cut -f3) at $(head -1 "$TEST_TIMING" | cut -f1)s)"
else
  echo "WARNING: no JUnit reports were read from the container, so $TEST_TIMING is empty."
fi
exit "$rc"
