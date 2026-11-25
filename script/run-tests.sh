#!/usr/bin/env bash
#
# Run the named test files in the devbooru stack, and the whole JS suite. The
# one runner both gates share: script/change-tests.sh (the commit gate) and
# script/fork-tests.sh (the deploy gate) each DERIVE a list and hand it here.
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

# NO TEST RUN CONTACTS AN OUTSIDE SITE (operator ruling 2026-11-24). Everything
# runs in the `test` service, whose one network has no route out. A Ruby test
# that tries is refused and named by test/test_helpers/outside_site_helper.rb;
# what that cannot see, a subprocess, is counted here in two readings over the
# whole run: lookups by name, and connects to an address (the kernel's count of
# packets it had no route for).
COMPOSE=(docker compose -f docker-compose.dev.yaml)
IN_TEST=("${COMPOSE[@]}" exec -T test)
TEST_CTR="$("${COMPOSE[@]}" ps -q --status running test)"
if [ -z "$TEST_CTR" ]; then
  echo "FAIL: the test container is not running, and tests run nowhere else."
  echo "fix:  bin/dev up -d test"
  exit 2
fi
no_routes() {
  "${IN_TEST[@]}" cat /proc/net/snmp /proc/net/snmp6 </dev/null \
    | awk '/^Ip: / && !col { for (i = 1; i <= NF; i++) if ($i == "OutNoRoutes") col = i; next }
           /^Ip: / { n += $col }
           /^Ip6OutNoRoutes/ { n += $2 }
           END { if (!col) exit 1; print n }'
}
# The watcher ends when its input does, so it never outlives this script.
coproc WATCH { docker run --rm -i --pull never --network "container:$TEST_CTR" --user 0 --cap-drop ALL --cap-add NET_RAW \
                 -v "$PWD:/danbooru:ro" --entrypoint bundle "$DEV_IMAGE" exec ruby script/lookup-watch.rb 2>&1; }
WATCH_IN="${WATCH[1]}"
exec {WATCH_OUT}<&"${WATCH[0]}"
read -r -t 60 -u "$WATCH_OUT" WATCH_UP
if [ "${WATCH_UP:-}" != watching ]; then
  echo "FAIL: the lookup watcher did not start: ${WATCH_UP:-no answer in 60s}"
  echo "fix:  run it by hand to see why: script/lookup-watch.rb, as script/run-tests.sh starts it"
  exit 2
fi
CONTROL="lookup-control-$$.41chan.net"
"${IN_TEST[@]}" getent hosts "$CONTROL" </dev/null >/dev/null
if ! ROUTES_BEFORE="$(no_routes)"; then
  echo "FAIL: the test container's count of packets with no route could not be read."
  echo "fix:  bin/dev exec test cat /proc/net/snmp, and find OutNoRoutes"
  exit 2
fi

# WORKERS=2 for a light run. vesper is the operator's workstation, and a run
# at every core made it unusable (2026-10-04). `nice` on this script does not
# reach the tests -- they run inside the container -- so the light run lowers
# their priority there too.
WORKERS="${WORKERS:-$(nproc --ignore=1)}"
LIGHT=()
[ -n "${LIGHT_RUN:-}" ] && LIGHT=(nice -n 19)
RUN=("${COMPOSE[@]}" exec -T
     -e RAILS_ENV=test -e PARALLEL_WORKERS="$WORKERS"
     test "${LIGHT[@]}" bin/rails test)

# THE LOAD AND LINT CHECKS RUN FIRST, IN BOTH TIERS, and a red one does not
# stop the run, so every red shows at once.
#   zeitwerk:check     every autoloaded file defines the constant its path names.
#   zeitwerk:shadowed  no autoloaded file is skipped because another root
#                      defines its constant (lib/tasks/fourier_zeitwerk.rake):
#                      zeitwerk:check stays green over that.
#   stylelint-all      every stylesheet, app/interfaces included. It sat in no
#                      gate and had rotted red when this was added (2026-11-15).
STATIC=("${COMPOSE[@]}" exec -T -e RAILS_ENV=test test "${LIGHT[@]}")
static_rc=0
ZW_OUT="$("${STATIC[@]}" bin/rails zeitwerk:check zeitwerk:shadowed </dev/null 2>&1)"
zw_rc=$?
if [ "$zw_rc" -eq 0 ]; then
  echo "zeitwerk:check and zeitwerk:shadowed: $(grep -E '^zeitwerk:shadowed:' <<< "$ZW_OUT")"
else
  grep -v ': warning: ' <<< "$ZW_OUT"
  echo "FAIL: bin/rails zeitwerk:check zeitwerk:shadowed exited $zw_rc."
  static_rc=$zw_rc
fi
SL_OUT="$("${STATIC[@]}" npm run -s stylelint-all -- --formatter unix </dev/null 2>&1)"
sl_rc=$?
if [ "$sl_rc" -eq 0 ]; then
  echo "stylelint-all: no problems"
else
  echo "$SL_OUT"
  echo "FAIL: npm run stylelint-all exited $sl_rc."
  static_rc=$sl_rc
fi

# THE JS SUITE RUNS WHOLE, IN BOTH TIERS. test/javascript is `node --test`
# over pure modules and takes seconds, so choosing among it would save
# nothing. It sat in no gate from 2026-10-17, when it was added, to
# 2026-10-25: both tiers chose *_test.rb files only.
JS_OUT="$("${IN_TEST[@]}" "${LIGHT[@]}" npm run -s test-js </dev/null 2>&1)"
js_rc=$?
if [ "$js_rc" -eq 0 ]; then
  echo "JS suite (npm run test-js): $(grep -oE '(tests|pass|fail) [0-9]+$' <<< "$JS_OUT" | paste -sd, -)"
else
  echo "$JS_OUT"
  echo "FAIL: the JS suite (npm run test-js) exited $js_rc; the Rails tests run anyway, so both reds show at once."
fi
echo

"${RUN[@]}" "$@"
rc=$?
[ "$rc" -eq 0 ] && rc=$js_rc
[ "$rc" -eq 0 ] && rc=$static_rc

# No reading is not a zero: a watcher that missed the lookup made for it to
# see, or a count that cannot be read, fails the run.
exec {WATCH_IN}>&-
LOOKUPS="$(timeout 60 cat <&"$WATCH_OUT")"
ROUTES_AFTER="$(no_routes)"
if ! grep -qF -- "$CONTROL" <<< "$LOOKUPS" || [ -z "$ROUTES_AFTER" ]; then
  echo "FAIL: whether a subprocess tried to go outside is not known: the lookup watcher did not report its control lookup, or the route count could not be read."
  echo "      the watcher said: ${LOOKUPS:-nothing}"
  echo "fix:  check the test container stayed up (bin/dev ps test), then rerun"
  [ "$rc" -eq 0 ] && rc=2
else
  LOOKUPS="$(grep -vF -- "$CONTROL" <<< "$LOOKUPS")"
  asked="$(awk '{ n += $1 } END { print n + 0 }' <<< "$LOOKUPS")"
  routes=$((ROUTES_AFTER - ROUTES_BEFORE))
  echo "unattributed attempts: $((asked + routes)) ($asked lookups by name, $routes packets to an address; none left the container)"
  [ -n "$LOOKUPS" ] && sed 's/^/  /' <<< "$LOOKUPS"
fi
[ -z "${TEST_TIMING:-}" ] && exit "$rc"
# The JUnit reporter has already timed every class, one report per class, in
# the container's tmp; its <testsuite> line carries the name, count and time.
mkdir -p "$(dirname "$TEST_TIMING")"
"${IN_TEST[@]}" \
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
