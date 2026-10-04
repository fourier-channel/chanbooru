# Where the deploy's build log lives, and the two sides of trusting it.
# Sourced, not run: bin/chanbooru-deploy writes the log, bin/build-watch reads
# it, and both take the location from here so there is one statement of it.
#
# WHY NOT /tmp. The log was /tmp/chanbooru-build.log: a fixed name in a
# world-writable directory that nothing installed. Any local user could plant
# a symlink there, and the deploy's `: > "$LOG"` and `tee "$LOG"` would then
# truncate and overwrite whatever it pointed at -- as root, under sudo
# (installed-locations audit 2026-10-04, bin/chanbooru-deploy:23 and :195).
#
# Now the log lives in tmp/chanbooru-deploy/ inside the deploy checkout (the
# repo ignores tmp/), a directory the deploy -- its writer -- installs at mode
# 700 and checks before every write. Nobody but its owner can put anything in
# it, so nothing in it can be a link someone else planted.

# build_log_dir ROOT -- the directory, given the checkout's top level.
build_log_dir() { printf '%s/tmp/chanbooru-deploy' "$1"; }

_build_log_fail() { echo "FAIL: $1" >&2; echo "fix:  $2" >&2; return 1; }

# install_build_log_dir DIR UID -- the writer's side. Makes DIR (mode 700) when
# it is missing, tightens it to 700 when it is ours, and refuses a link, a
# directory owned by anyone else, or a link where the log or its predecessor
# would go.
install_build_log_dir() {
  local dir=$1 uid=$2 owner f
  if [[ -L "$dir" ]]; then
    _build_log_fail "$dir is a symlink (to $(readlink "$dir")). The deploy makes its log directory itself." \
      "rm $dir and deploy again; it is recreated"
    return 1
  fi
  if [[ ! -e "$dir" ]]; then
    mkdir -p "$(dirname "$dir")" && mkdir -m 700 "$dir" \
      || { _build_log_fail "could not create $dir." "check that $(dirname "$dir") is writable by uid $uid"; return 1; }
  fi
  if [[ ! -d "$dir" ]]; then
    _build_log_fail "$dir exists but is not a directory." "move it aside and deploy again"
    return 1
  fi
  owner="$(stat -c %u "$dir")"
  if [[ "$owner" != "$uid" ]]; then
    _build_log_fail "$dir is owned by uid $owner, not uid $uid who is deploying." \
      "deploy as uid $owner, or remove $dir so this deploy installs its own"
    return 1
  fi
  chmod 700 "$dir" || { _build_log_fail "could not chmod 700 $dir." "chmod 700 $dir"; return 1; }
  for f in "$dir/build.log" "$dir/build.log.prev"; do
    if [[ -L "$f" ]]; then
      _build_log_fail "$f is a symlink; the deploy will not write through it." "rm $f and deploy again"
      return 1
    fi
  done
}

# check_build_log_dir DIR UID -- the reader's side. Never creates anything.
check_build_log_dir() {
  local dir=$1 uid=$2 owner mode
  if [[ -L "$dir" ]]; then
    _build_log_fail "$dir is a symlink (to $(readlink "$dir")), not the directory bin/chanbooru-deploy installs." \
      "rm $dir; the next bin/chanbooru-deploy makes the real one"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    _build_log_fail "no build log directory at $dir. bin/chanbooru-deploy installs it when it builds; no deploy has built from this checkout yet." \
      "run bin/chanbooru-deploy, or pass a log path: bin/build-watch --summary /path/to/build.log"
    return 1
  fi
  owner="$(stat -c %u "$dir")"
  if [[ "$owner" != "$uid" ]]; then
    _build_log_fail "$dir is owned by uid $owner, not you (uid $uid)." \
      "run bin/build-watch as the user who ran the deploy (uid $owner)"
    return 1
  fi
  mode="$(stat -c %a "$dir")"
  if (( 8#$mode & 8#077 )); then
    _build_log_fail "$dir is mode $mode; the deploy installs it 700." \
      "chmod 700 $dir, or deploy again (the deploy sets it)"
    return 1
  fi
  if [[ -L "$dir/build.log" ]]; then
    _build_log_fail "$dir/build.log is a symlink, not a log the deploy wrote." "rm $dir/build.log"
    return 1
  fi
}
