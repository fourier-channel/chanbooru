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
#
# The app is upstream's, taken from its image; the Ruby under it is not.
# Upstream built on ruby:3.4.4-slim-bookworm, which carries CVE-2026-97229
# (critical, in CISA KEV; fixed in 3.4.12), so this rebuilds on 3.4.12 the way
# upstream's Dockerfile does: its build packages, its danbooru user (uid 1000),
# its run and log dirs.
FROM ghcr.io/danbooru/archives@sha256:46eca16bc5f80bcf83d3a9a98a338b11dd63ab2aa3f288424343defb72660da4 AS upstream

FROM ruby:3.4.12-slim-bookworm@sha256:c81ac5a2118161a9e01cfbb2da6d68ae1c96d3e6dff14fb1f7f485fee538babe
LABEL archives=true
ENV RAILS_ENV=production

# Debian bookworm as published at 2026-11-09, not "whatever is current".
RUN printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/20261109T000000Z\nSuites: bookworm bookworm-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://snapshot.debian.org/archive/debian-security/20261109T000000Z\nSuites: bookworm-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' > /etc/apt/sources.list.d/debian.sources \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false upgrade -y \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends build-essential libxml2-dev libyaml-dev libpq-dev \
 && DEBIAN_FRONTEND=noninteractive apt-get purge -y libexpat1 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && useradd -ms /bin/bash danbooru -u 1000 \
 && mkdir /var/run/danboorus /var/log/archives \
 && chown danbooru:danbooru /var/run/danboorus /var/log/archives
COPY --from=upstream --chown=danbooru:danbooru /app /app
# libexpat1 is purged, not upgraded: nothing the app runs links it -- only
# fontconfig, libgd and libc-devtools' memusagestat, which the purge takes with
# it (scan and ldd of 2026-10-24) -- so it is scanner surface only. It carried
# highs (CVE-2025-59375, CVE-2026-77214) until deb12u5. smoke.sh checks it
# stays gone.
# Ruby 3.4.4's default erb 4.0.4 and bundled net-imap 0.5.8 carried highs with a
# fix (scan of 2026-10-24). The bundle's erb (Gemfile) is what loads, also for a
# plain `require "erb"`; net-imap is not in Gemfile.lock, so bundle exec cannot
# load it. Both were scanner surface only, so they are removed, not upgraded,
# whichever versions the Ruby ships (3.4.12: erb 4.0.4.1, net-imap 0.5.15).
# smoke.sh checks that neither comes back.
RUN R=/usr/local/lib/ruby \
 && rm -rf $R/gems/3.4.0/specifications/default/erb-*.gemspec $R/gems/3.4.0/gems/erb-* \
      $R/3.4.0/erb.rb $R/3.4.0/erb $R/3.4.0/x86_64-linux/erb /usr/local/bin/erb \
 && gem uninstall -i $R/gems/3.4.0 net-imap --all --executables --force
# The processor's logger at WARN, its one edit to upstream's app. At the default
# it logged every post and pool version it archived, the whole row as JSON:
# ~1,800 lines an hour on the serving box (2026-11-03), a copy of what the
# archive database holds. Its errors still print. The build fails if the line
# has moved. smoke.sh checks the level.
RUN F=/app/services/sqs_processor.rb \
 && grep -qx 'LOGGER = Logger.new($stderr)' $F \
 && sed -i 's/^LOGGER = Logger.new(\$stderr)$/LOGGER = Logger.new($stderr, level: Logger::WARN)/' $F \
 && grep -qx 'LOGGER = Logger.new($stderr, level: Logger::WARN)' $F

USER danbooru
WORKDIR /app
COPY --chown=danbooru:danbooru Gemfile Gemfile.lock ./
RUN BUNDLE_FROZEN=1 bundle install && bundle clean --force
