# frozen_string_literal: true

# ONE-CLICK BANISH, the jailing half (operator rulings 2026-10-12). An admin
# banishes a flagged tag from the review queue (TagQuarantine#banish!): the
# state flips in one transaction, so every carrier is withheld from everyone
# but the pipeline at once; then this jails every post carrying the name
# through the booru's own jail (Post#jail_by_booru!, as the system user), and
# each jailing reaches the jail panel as a post_jail row on the feed it
# already reads (GET /fourier_jail/release.json?since=), actor "banish".
#
# The reason names the actor, never the tag: deletion flags and the mod log
# are read far more widely than a banished name may travel.
#
# A post already jailed (a legal hold included) is left alone. A post a human
# once released IS jailed again: a banish is a deliberate act, and sampling
# records it as a human re-jail. A rerun jails only the posts still left.
#
# A tag UNBANISHED meanwhile -- the jail panel can take it off the list while
# this is queued or running (operator ruling 2026-10-12) -- jails nothing
# more: each post asks whether the tag is still banished, under its lock, so
# a long run stops at the unbanish instead of jailing the rest of a tag that
# is back to normal. What it jailed before stays jailed; releasing those is
# the panel's per-post release.
class BanishTagJob < ApplicationJob
  queue_as :default

  def self.reason(admin) = "#{Post::JAIL_DELETION_REASON}#{admin.name} banished a tag, from the review queue"

  def perform(tag_id, admin_id)
    tag = Tag.find(tag_id)
    admin = User.find(admin_id)
    reason = self.class.reason(admin)
    jail = Danbooru.config.troll_jail_tag
    posts = Post.where_array_includes_any("string_to_array(posts.tag_string, ' ')", [tag.name])
    total = posts.count
    jailed = skipped = 0
    unbanished = false

    posts.find_each.with_index(1) do |post, n|
      post.with_lock do
        unless TagQuarantine.banished.exists?(tag_id: tag.id)
          unbanished = true
          skipped += 1
          next
        end
        if post.jailed? || post.legal_hold?
          skipped += 1
          next
        end

        # Jail first, tag after (Post#jail_by_booru!'s convention): the
        # post_jail row then carries this reason whether the post was live or
        # already deleted by someone else, and the tagging save that follows
        # finds a jailing standing and reports nothing of its own.
        CurrentUser.set(user: User.system, safe_mode: false) do
          post.jail_by_booru!(reason)
          unless post.has_tag?(jail)
            post.add_tag(jail)
            post.save!
          end
        end
        jailed += 1
      end
      Rails.logger.info("[banish_tag] tag ##{tag.id}: #{n}/#{total} post ##{post.id}")
    rescue ActiveRecord::ActiveRecordError => e
      # One bad post never aborts the rest -- and is said, with the remedy.
      skipped += 1
      Rails.logger.error("[banish_tag] tag ##{tag.id}: post ##{post.id} NOT jailed (#{e.class}: #{e.message}); rerun BanishTagJob.perform_now(#{tag.id}, #{admin.id}) to retry the posts still left")
    end
    Rails.logger.info("[banish_tag] tag ##{tag.id}: #{jailed} jailed, #{skipped} skipped, of #{total}#{" -- unbanished during the run, so the rest were left alone" if unbanished}")
  end
end
