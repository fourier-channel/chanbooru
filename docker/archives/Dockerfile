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
 && DEBIAN_FRONTEND=noninteractive apt-get purge -y libexpat1 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# libexpat1 is purged, not upgraded: its highs (CVE-2025-59375, CVE-2026-77214)
# were fixed in deb12u5 on 2026-10-22, inside the cooldown, and nothing the app
# runs links it -- only fontconfig, libgd and libc-devtools' memusagestat, which
# the purge takes with it (scan and ldd of 2026-10-24). smoke.sh checks it stays
# gone.
# Ruby 3.4.4's default erb 4.0.4 and bundled net-imap 0.5.8 carried highs with a
# fix (scan of 2026-10-24). The bundle's erb (Gemfile) is what loads, also for a
# plain `require "erb"`; net-imap is not in Gemfile.lock, so bundle exec cannot
# load it. Both were scanner surface only, so they are removed, not upgraded.
# smoke.sh checks that neither comes back.
RUN R=/usr/local/lib/ruby \
 && rm -rf $R/gems/3.4.0/specifications/default/erb-4.0.4.gemspec $R/gems/3.4.0/gems/erb-4.0.4 \
      $R/3.4.0/erb.rb $R/3.4.0/erb $R/3.4.0/x86_64-linux/erb /usr/local/bin/erb \
 && gem uninstall -i $R/gems/3.4.0 net-imap -v 0.5.8 --executables --force

USER danbooru
WORKDIR /app
COPY --chown=danbooru:danbooru Gemfile Gemfile.lock ./
RUN BUNDLE_FROZEN=1 bundle install && bundle clean --force
