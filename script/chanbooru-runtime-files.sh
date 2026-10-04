# What the production image carries that a release does not: Ruby, the system
# packages and the gems. A commit touching any of these needs a new image;
# anything else ships as a release (bin/chanbooru-release). Sourced by
# bin/chanbooru-deploy, which rebuilds the image when one of these changed
# since it was built, and by script/fork-tests.sh, which warns when the dev
# image on a workstation was built from a different runtime than HEAD's.
# Kept to what changes the image's CONTENTS: the build script and the builder's
# config change how it is built, not what it holds.
# shellcheck disable=SC2034
RUNTIME_FILES=(Dockerfile Gemfile Gemfile.lock lib/dtext_rb .ruby-version)
