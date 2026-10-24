#!/usr/bin/env bash
# Smoke run for chanbooru-archives (bin/chanbooru-image): the gems resolve
# frozen, and everything the processor and the queue script load, loads, at
# the versions the Gemfile floors name. No network: nothing here may reach out.
set -euo pipefail
docker run --rm --network none "$1" sh -c 'bundle check && bundle exec ruby -Imodels -e "
  require \"dotenv\"; require \"logger\"; require \"aws-sdk\"; require \"optparse\"
  require \"pool_version\"; require \"post_version\"; require \"nokogiri\"; require \"rack\"
  Aws::SQS::Client; Aws::SQS::QueuePoller
  want = { \"nokogiri\" => \"1.19.4\", \"rack\" => \"3.1.22\", \"rack-session\" => \"2.1.2\", \"concurrent-ruby\" => \"1.3.8\", \"crass\" => \"1.0.7\", \"erb\" => \"6.0.7\", \"activerecord\" => \"8.0.5.1\", \"activesupport\" => \"8.0.5.1\", \"actionview\" => \"8.0.5.1\", \"rails-html-sanitizer\" => \"1.7.1\", \"loofah\" => \"2.25.2\", \"uri\" => \"1.1.2\" }
  have = want.to_h { |g, _| [g, Gem.loaded_specs.fetch(g).version.to_s] }
  abort \"gem versions: want #{want}, have #{have}\" unless have == want
  puts \"archives smoke ok: ruby #{RUBY_VERSION}, activerecord #{ActiveRecord.version}, #{have.map { |g, v| \"#{g} #{v}\" }.join(\", \")}\"
"'
# Outside bundle exec, which hides every gem not in Gemfile.lock: Ruby's own erb
# 4.0.4 and net-imap 0.5.8 were removed (Dockerfile), so the only erb installed
# is the bundle's, a plain require gets it, and net-imap is gone.
docker run --rm --network none "$1" ruby -e '
  erbs = Gem::Specification.find_all_by_name("erb").map { _1.version.to_s }
  abort "erb installed: want only 6.0.7, have #{erbs}" unless erbs == ["6.0.7"]
  imaps = Gem::Specification.find_all_by_name("net-imap").map { _1.version.to_s }
  abort "net-imap installed: #{imaps}; nothing loads it" unless imaps.empty?
  require "erb"
  abort "require \"erb\" loaded #{ERB.version}" unless ERB.version == "6.0.7"
  puts "archives smoke ok: erb #{ERB.version} only, no net-imap"
'
# The old erb's files, not just its gemspec: without RubyGems a require finds
# only the stdlib, which must no longer have one. And libexpat1 stays purged.
docker run --rm --network none "$1" sh -c '! ruby --disable-gems -e "require \"erb\"" 2>/dev/null && ! dpkg -s libexpat1 >/dev/null 2>&1 && echo "archives smoke ok: no stdlib erb, no libexpat1"'
