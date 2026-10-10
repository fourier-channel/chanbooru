# frozen_string_literal: true

# Report the booru's own jailings from before 2026-10-10 to the jail panel,
# and make the post page pill's past jail-ons releasable from it
# (app/logical/fourier_past_jailings.rb says why and what is written).
#
#   bin/rails runner script/fourier_report_past_jailings.rb              dry run
#   bin/rails runner script/fourier_report_past_jailings.rb -- --apply   write
#
# The dry run lists every post it would write for, one tab-separated line
# each: post, kind (banished, pill or tagged), whether it carries troll_jail
# now, the account that deleted it, and the reason. Read it before --apply:
# the pill's rows are picked by their words.
require "optparse"

apply = false
parser = OptionParser.new do |opts|
  # A write is asked for by its whole name, never an abbreviation.
  opts.require_exact = true
  opts.on("--apply") { apply = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  the only option is --apply, spelled out in full; run with none for a dry run."
  exit 2
end

plan = FourierPastJailings.plan
plan.each do |post, row, kind|
  deleted_by = row ? "deleted by #{row.creator.name} (##{row.creator_id})" : "deletion not logged"
  tagged = post.has_tag?(Danbooru.config.troll_jail_tag) ? "tagged" : "untagged"
  puts "post ##{post.id}\t#{kind}\t#{tagged}\t#{deleted_by}\t#{row&.description}"
end
puts "#{plan.size} past jailing(s) to report#{" -- DRY RUN, nothing written; run again with -- --apply" unless apply}"
exit 0 unless apply

written = FourierPastJailings.apply!(plan, progress: ->(line) { puts line })
puts "reported #{written} past jailing(s); fourier-sampling takes them in on its next booru pass (GET /fourier_jail/release.json)"
