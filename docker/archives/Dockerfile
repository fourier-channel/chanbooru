# chanbooru-archives: upstream's archives service (ghcr.io/danbooru/archives),
# its app unchanged, with the Debian and gem fixes upstream has not shipped.
# Upstream's image of 2025-06-03 carried 43 fixable criticals (scan of
# 2026-10-24); this one carries none.
#
# BUILT ON THE WORKSTATION, NEVER ON THE SERVING BOX. bin/chanbooru-image
# builds it from this directory at a commit, scans it, smoke-runs it and
# promotes it with docker save | docker load (D-246054: the box runs promoted
# artifacts). The serving box needs no route to snapshot.debian.org or
# rubygems.org, and compose names the image with pull_policy: never, so a
# missing image fails the deploy instead of fetching something else.
# Recovering it therefore needs a box that reaches both hosts, and this
# directory at the deployed commit.
#
# Update: move the snapshot date and the gem floors in Gemfile (each release
# >= 3 days old: org cooldown), relock with `bundle lock --update <gems>
# --conservative && bundle lock --add-checksums` inside the FROM image, then
# bin/chanbooru-image archives promote.
FROM ghcr.io/danbooru/archives@sha256:46eca16bc5f80bcf83d3a9a98a338b11dd63ab2aa3f288424343defb72660da4

USER root
# Debian bookworm as published at 2026-10-20, not "whatever is current".
RUN printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/20261020T000000Z\nSuites: bookworm bookworm-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://snapshot.debian.org/archive/debian-security/20261020T000000Z\nSuites: bookworm-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' > /etc/apt/sources.list.d/debian.sources \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false upgrade -y \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

USER danbooru
WORKDIR /app
COPY --chown=danbooru:danbooru Gemfile Gemfile.lock ./
RUN BUNDLE_FROZEN=1 bundle install && bundle clean --force
