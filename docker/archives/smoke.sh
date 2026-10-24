#!/usr/bin/env bash
# Smoke run for chanbooru-archives (bin/chanbooru-image): the gems resolve
# frozen, and everything the processor and the queue script load, loads, at
# the versions the Gemfile floors name. No network: nothing here may reach out.
set -euo pipefail
docker run --rm --network none "$1" sh -c 'bundle check && bundle exec ruby -Imodels -e "
  require \"dotenv\"; require \"logger\"; require \"aws-sdk\"; require \"optparse\"
  require \"pool_version\"; require \"post_version\"; require \"nokogiri\"; require \"rack\"
  Aws::SQS::Client; Aws::SQS::QueuePoller
  want = { \"nokogiri\" => \"1.19.4\", \"rack\" => \"3.1.22\", \"rack-session\" => \"2.1.2\", \"concurrent-ruby\" => \"1.3.8\", \"crass\" => \"1.0.7\", \"erb\" => \"6.0.7\" }
  have = want.to_h { |g, _| [g, Gem.loaded_specs.fetch(g).version.to_s] }
  abort \"gem versions: want #{want}, have #{have}\" unless have == want
  puts \"archives smoke ok: ruby #{RUBY_VERSION}, activerecord #{ActiveRecord.version}, #{have.map { |g, v| \"#{g} #{v}\" }.join(\", \")}\"
"'
