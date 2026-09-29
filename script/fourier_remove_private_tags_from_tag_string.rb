# frozen_string_literal: true

# List -- and, with --apply, remove -- private creator tags that still sit in a
# post's PUBLIC tag_string (round-two finding 15). The rules, and why any post
# carries one, are in app/logical/fourier_private_tag_cleanup.rb; this only
# runs them.
#
#   bin/rails runner script/fourier_remove_private_tags_from_tag_string.rb              dry run
#   bin/rails runner script/fourier_remove_private_tags_from_tag_string.rb -- --apply   remove
#
# Options (after `--`, so rails runner leaves them alone):
#   --apply   edit the listed posts, as the system user; without it nothing is
#             written. Spelled out in full: an abbreviation is refused, never
#             completed to --apply.
#
# Output is tab-separated, post ids and counts only -- never a tag, because the
# tags are the private data (FourierPrivateTagCleanup.report_lines).
require "optparse"

options = { apply: false }
parser = OptionParser.new do |opts|
  # OptionParser completes an unambiguous prefix by default, so -a, --a and
  # --ap would all mean --apply. A write is asked for by its whole name.
  opts.require_exact = true
  opts.on("--apply") { options[:apply] = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  the only option is --apply, spelled out in full; run with no options for a dry run."
  exit 2
end

plan = FourierPrivateTagCleanup.plan
puts FourierPrivateTagCleanup.report_lines(plan)

unless options[:apply]
  puts "# DRY RUN: nothing was written. Re-run with -- --apply to edit the #{plan.posts.size} post(s)."
  exit 0
end

unless plan.versions_kept
  warn "FAIL: post versions are not kept here (PostVersion.enabled? is false), so a removal could not be reverted."
  warn "fix:  configure the post archive (aws_sqs_archives_url) before applying; the dry run above is unaffected."
  exit 2
end

user = User.system
result = FourierPrivateTagCleanup.apply!(plan, user: user)
puts FourierPrivateTagCleanup.result_lines(result, user: user)
exit(result[:failed].empty? ? 0 : 1)
