# frozen_string_literal: true

# Propose -- and, with --apply, record -- a creator for tunnel posts made
# before creators were recorded (operator ruling 2026-09-29). The rules are
# in app/logical/fourier_creator_backfill.rb; this only runs them.
#
#   bin/rails runner script/fourier_backfill_post_creators.rb              dry run
#   bin/rails runner script/fourier_backfill_post_creators.rb -- --apply   record
#
# Options (after `--`, so rails runner leaves them alone), each spelled out
# in full -- an abbreviation is refused, never completed (-a, --a and --ap
# once all meant --apply):
#   --apply               write the proposals; without it nothing is written
#   --uploader NAME       the tunnel's booru account (default: tunnel, its name
#                         on production); it must be one of
#                         Danbooru.config.fourier_posting_bot_names
#   --recorded-by NAME    the booru account the rows are recorded by (default:
#                         the system user)
#
# Every run first checks that list against the accounts that exist, and
# warns about a name that matches none: a renamed bot is a PERSON to
# FourierCreatorPrivacy, the creator of every post it uploaded that has no
# recorded creator.
#
# Output is tab-separated, one line per post (see
# FourierCreatorBackfill.report_lines), so a dry run can be saved, read, and
# compared with the apply run that follows it.
require "optparse"

options = { apply: false, uploader: "tunnel", recorded_by: nil }
parser = OptionParser.new do |opts|
  # OptionParser completes an unambiguous prefix by default. A write is asked
  # for by its whole name.
  opts.require_exact = true
  opts.on("--apply") { options[:apply] = true }
  opts.on("--uploader NAME") { |name| options[:uploader] = name }
  opts.on("--recorded-by NAME") { |name| options[:recorded_by] = name }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  the options are --apply, --uploader NAME and --recorded-by NAME, spelled out in full; run with none for a dry run."
  exit 2
end

FourierCreatorBackfill.unmatched_bot_names.each do |name|
  warn "WARNING: posting bot #{name.inspect} (Danbooru.config.fourier_posting_bot_names) matches no booru account."
  warn "         If that bot was renamed, its account is now a PERSON to FourierCreatorPrivacy: the creator of every post"
  warn "         it uploaded that has no recorded creator. fix: put the account's current name in the list."
end

uploader = User.find_by_name(options[:uploader])
if uploader.nil?
  warn "FAIL: no booru account named #{options[:uploader].inspect}."
  warn "fix:  pass --uploader with the account fourier-tunnel posts as."
  exit 2
end
unless FourierCreatorPrivacy.posting_bot?(uploader)
  warn "FAIL: #{uploader.name} is not a posting bot (Danbooru.config.fourier_posting_bot_names)."
  warn "fix:  a person's uploads already have their creator -- the uploader. Pass the tunnel's account, or add it to that list."
  exit 2
end

recorder = options[:recorded_by] ? User.find_by_name(options[:recorded_by]) : User.system
if recorder.nil?
  warn "FAIL: no booru account named #{options[:recorded_by].inspect} to record the rows as."
  warn "fix:  pass --recorded-by with an existing account, or omit it to use the system user."
  exit 2
end

plan = FourierCreatorBackfill.plan(uploader: uploader)
puts FourierCreatorBackfill.report_lines(plan)

unless options[:apply]
  puts "# DRY RUN: nothing was written. Re-run with -- --apply to record the #{plan.proposals.size} proposal(s)."
  exit 0
end

result = FourierCreatorBackfill.apply!(plan, recorded_by: recorder)
result[:failed].each { |post_id, message| puts "FAILED\t#{post_id}\t#{message}" }
puts "# APPLIED as #{recorder.name}: #{result[:recorded]} recorded, #{result[:kept]} kept an existing creator, #{result[:failed].size} failed"
exit(result[:failed].empty? ? 0 : 1)
