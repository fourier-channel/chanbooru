# frozen_string_literal: true

# Put troll_jail back on every jailed post that lost it (boo.122 residual,
# 2026-11-20).
#
#   bin/rails runner script/fourier_retag_untagged_jailings.rb              dry run
#   bin/rails runner script/fourier_retag_untagged_jailings.rb -- --apply   write
#
# Post.untagged_jailed_ids is every post the jail holds (deleted by the jail,
# or reported as a jailing) whose tag string no longer carries troll_jail.
# fourier-sampling's tagger made them: it queued a tag push before awaiting
# its own jail, and the push, saved from a read taken before the jail's tag
# edit, took the tag off (106 in November 2026; 429 on 2026-11-20). The
# booru already treats them as jailed by the log; this puts the tag back so
# the tag and the log say the same thing again.
#
# Each post is re-tagged with Post#add_jail_tag!, the one save R2 lets
# through for the booru's own jail acts, as the system user and under the
# post's row lock. Nothing else about a post changes. The dry run lists the
# posts by id and writes nothing. Output is ids and counts only: never a
# post's tags (operator 2026-11-11, tags may be a creator's secret).
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

# A production runner has no statement timeout of its own.
ActiveRecord::Base.connection.execute("SET statement_timeout = '60s'")

jail = Danbooru.config.troll_jail_tag
ids = Post.untagged_jailed_ids_now
total = ids.size
puts "#{total} jailed post(s) without #{jail}#{" -- DRY RUN, nothing written; run again with -- --apply" unless apply}"
unless apply
  ids.each_with_index { |id, i| puts "#{i + 1}/#{total}\tpost ##{id}\twould be re-tagged" }
  exit 0
end

# The jail feed lists post_jail rows. Re-tagging is the jail acting, so it
# must write none (Post#report_jailing_entered skips a jail account's
# tagging): one written would reach the panel as a jailing it never made.
# Counted on these posts only, so a jailing elsewhere meanwhile is not one.
reports = -> { ModAction.where(category: :post_jail, subject_type: "Post", subject_id: ids).count }
reports_before = reports.call
retagged = 0
failed = []
CurrentUser.scoped(User.system) do
  ids.each_with_index do |id, i|
    post = Post.find(id)
    post.with_lock { post.add_jail_tag! }
    retagged += 1
    puts "#{i + 1}/#{total}\tpost ##{id}\tre-tagged"
  rescue ActiveRecord::RecordNotSaved => e
    # add_jail_tag!'s own refusal names no tag but troll_jail and its fix.
    failed << id
    puts "#{i + 1}/#{total}\tpost ##{id}\tFAILED: #{e.message}"
  rescue StandardError => e
    # Any other error's message can quote the post's tags: its class only.
    failed << id
    puts "#{i + 1}/#{total}\tpost ##{id}\tFAILED: #{e.class}#{e.respond_to?(:record) && e.record ? " (#{e.record.errors.count} validation error(s))" : ""}"
  end
end

Post.jail_state_changed!
remaining = Post.untagged_jailed_ids_now.size
reported = reports.call - reports_before
puts "re-tagged #{retagged} of #{total}; #{failed.size} failed; #{remaining} jailed post(s) still without #{jail}; #{reported} new jailing report(s) (post_jail)"
if reported.positive?
  warn "FAIL: re-tagging wrote #{reported} jailing report(s); the jail panel's feed will show them as jailings by #{User.system.name}."
  warn "fix:  Post#report_jailing_entered must skip a jail account tagging a deleted post; restore that, then tell the jail panel's owner which posts were reported."
end
if failed.any? || remaining.positive?
  warn "FAIL: #{failed.size} post(s) were not re-tagged and #{remaining} remain without #{jail}."
  warn "fix:  open each failed post as an admin and read its errors; then run this script again (dry run first)."
end
exit 1 if reported.positive? || failed.any? || remaining.positive?
