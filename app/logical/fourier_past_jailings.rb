# frozen_string_literal: true

# The jailings the booru made itself BEFORE it reported them to the jail
# panel (2026-10-10), brought into that report, run by the operator through
# script/fourier_report_past_jailings.rb.
#
# Operator 2026-10-09: "The booru should obviously communicate back to the
# panel that is controlling the visibility of posts on the booru." From
# 2026-10-10 every booru-side jailing writes a post_jail row
# (Post#jail_by_booru!), which GET /fourier_jail/release.json lists. The
# ones before it wrote none. Measured on production that day (read-only):
#
#   - 4 banished-tag jailings by the system user, all still deleted. Their
#     deletion is already the jail's; only the report is missing.
#   - 45 jail-ons from the post page pill, all still deleted, each DELETED
#     BY THE MODERATOR ("troll jail: moderator, from the post page"). The
#     release route proves a jailing by who deleted, so these read as a
#     moderator's ordinary deletion: release would lift the tag and leave
#     them deleted for good.
#
#   - deleted posts carrying troll_jail under someone else's deletion, with
#     no report: the old pill's jail-on of a post already deleted (it added
#     the tag and nothing else), or a tagged post a moderator deleted. Each
#     is jailed (operator ruling 2026-10-10: a deleted post carrying the
#     tag), so every ordinary undelete door refuses it, and the panel has no
#     row to release it from (review of the 2026-10-10 build).
#
# For each, if the post is still deleted under that deletion, this writes
# what the booru writes today: for the pill's, the deletion recorded as the
# system user's on the moderator's behalf (a post_delete mod action naming
# them; the pill's was the only act, nothing is deleted again); for every
# one, the post_jail row that reports it. Picking the pill's rows by their
# words is the one place reason text is read, and it is safe only because a
# person runs it once and reads the dry run's list first: every row names
# the account that deleted it, and whether the post still carries the tag.
module FourierPastJailings
  PILL_REASON = "troll jail: moderator, from the post page"
  TAGGED_REASON = "troll jail: tagged troll_jail while deleted, before the booru reported its jailings"

  # [post, mod_action, kind] for each past booru-side jailing still standing
  # and not yet reported: kind is :banished (the system user's), :pill (a
  # moderator's, by the pill's words) or :tagged (the tag on someone else's
  # deletion; the row is that deletion's, or nil when none was logged).
  def self.plan
    reported = ModAction.where(category: :post_jail, subject_type: "Post").select(:subject_id)
    candidates = ModAction.where(category: :post_delete, subject_type: "Post").where.not(subject_id: reported).order(:id)
    system = candidates.where(creator: User.system).where("description LIKE ?", "deleted post #%, reason: #{Post::JAIL_DELETION_REASON}%")
    pill = candidates.where.not(creator: User.system).where("description LIKE ('deleted post #' || subject_id || ', reason: ' || ?)", PILL_REASON)
    planned = (system.map { |row| [row, :banished] } + pill.map { |row| [row, :pill] }).filter_map do |row, kind|
      post = Post.find_by(id: row.subject_id)
      latest = post && ModAction.where(subject: post, category: [:post_delete, :post_undelete]).order(:id).last
      next unless post&.is_deleted? && latest&.id == row.id
      # The old pill's jail-off took the tag and left the post deleted: a
      # moderator's decision that it was no longer jailed. Never re-jailed.
      next if kind == :pill && !post.has_tag?(Danbooru.config.troll_jail_tag)

      [post, row, kind]
    end
    seen = planned.to_set { |post, _row, _kind| post.id }
    tagged = Post.where(is_deleted: true).where.not(id: reported).tags_include(Danbooru.config.troll_jail_tag).order(:id).filter_map do |post|
      next if seen.include?(post.id) || post.deletion_is_the_jails?

      [post, ModAction.where(subject: post, category: :post_delete).order(:id).last, :tagged]
    end
    planned + tagged
  end

  # Writes the plan's rows. Returns how many posts were reported.
  def self.apply!(plan, progress: ->(_line) {})
    plan.each_with_index do |(post, row, kind), index|
      case kind
      when :pill then reason = "#{Post::JAIL_DELETION_REASON}moderator #{row.creator.name}, from the post page"
      when :tagged then reason = TAGGED_REASON
      else reason = row.description.sub(/\Adeleted post #\d+, reason: /, "")
      end
      ModAction.transaction do
        ModAction.log("deleted post ##{post.id}, reason: #{reason}", :post_delete, subject: post, user: User.system) if kind == :pill
        ModAction.log("jailed post ##{post.id}, reason: #{reason}", :post_jail, subject: post, user: User.system)
      end
      progress.call("#{index + 1}/#{plan.size}\tpost ##{post.id}\t#{kind}\t#{reason}")
    end
    plan.size
  end
end
