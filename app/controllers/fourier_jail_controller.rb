# frozen_string_literal: true

# The jail panel's door into the booru: releasing an image from
# fourier-sampling's troll jail (POST), and the booru's own jailings reported
# back to the panel (GET). Both answer only the jail panel's account
# (Danbooru.config.fourier_jail_release_names): operator ruling 2026-10-09,
# release happens only from the jail panel, by the jail account, and "The
# booru should obviously communicate back to the panel that is controlling
# the visibility of posts on the booru."
#
# WHY RELEASE IS ITS OWN VERB. Jailing an image deletes its booru post;
# releasing it has to bring the post back, and sampling could not, for two
# reasons measured against production on 2026-09-06:
#
#   1. fourier-sampling finds a post by searching `md5:<hash>`, and the search
#      index hides deleted posts from anyone below deleted_post_visibility_level
#      (ADMIN). The sampling bot is an Approver, so the lookup returned nothing.
#   2. Even with the id in hand, POST /post_approvals.json refuses: undeleting
#      is approving, and PostApproval rejects approving your own upload unless
#      you are an admin. The bot uploaded every post it jails. HTTP 422, "You
#      cannot approve a post you uploaded".
#
# Raising the bot to ADMIN or relaxing PostApprovalPolicy were rejected: the
# first hands an account whose key sits on a scraping box the run of the site,
# the second lets any approver undo a moderator's deletion of their own post.
# This is one verb, fork-local, that can ONLY reverse a jailing.
#
# WHAT IT RELEASES. A jailed post is a deleted post carrying troll_jail
# (operator ruling 2026-10-10: "Jailed means deleted"), and release takes the
# tag off AND undeletes it, in one save. It undoes a deletion only when that
# deletion is the jail's (Post#deletion_is_the_jails?): the latest logged
# deletion was made by a jail account -- sampling's, or the system user the
# booru's own jailings act as -- under the name it held then, and no
# undeletion has been logged since. Proved by WHO deleted, never by the
# reason text, which any approver types into DELETE /posts/:id. So:
#
#   - deleted, the jail's deletion: released (untagged and undeleted). That
#     includes a post whose tag is gone -- the pill's old jail-off left four
#     production posts deleted that way (2026-09-20);
#   - deleted, someone else's deletion: the jail's tag is lifted if it is
#     there, a reported jailing standing on that deletion is closed
#     (post_unjail, Post#jailing_stands?), and that deletion stands (422,
#     deleted: true, jailed: false) -- a moderator's deletion is never
#     undone through here, tagged or not;
#   - a legal hold (deleted "troll jail: radioactive" BY A JAIL ACCOUNT, ever):
#     nothing changes, ever (operator ruling 2026-10-08). An approver who
#     types those words has made an ordinary deletion, not a hold.
#
# `deleted` and `jailed` in a 422 are the post's state after the answer, so
# the caller can tell a finished release from a stuck one without reading the
# post back, which it cannot do for a deleted post.
class FourierJailController < ApplicationController
  respond_to :json

  # Kept in step with fourier-sampling's JAIL_TAG (src/booru/jailSync.ts).
  JAIL_TAG = "troll_jail"

  NOT_THE_JAILS = "deleted, but not by the jail: its current deletion is not a jailing, and release never undoes another deletion"
  A_LEGAL_HOLD = "a legal hold (troll jail: radioactive): release never undeletes or untags one"

  # The most jail events one GET answers; the caller pages by `since`.
  EVENTS_PER_PAGE = 200

  # How old a row must be before the cursor moves past it. Ids are handed
  # out at INSERT and rows become visible at COMMIT, so a jailing written
  # inside a longer transaction (the banished-tag failsafe runs inside an
  # upload's save) can appear BELOW a row already read, and a cursor that
  # had passed it would skip it forever (review of the 2026-10-10 build).
  # Younger rows are still listed -- the panel acts on them at once and a
  # re-read is harmless to it -- but the cursor stops before the first one.
  SETTLE = 30.seconds

  # GET /fourier_jail/release.json?since=<id>: every jailing the booru made
  # itself (the post_jail rows Post#jail_by_booru! and
  # Post#report_jailing_entered write) after the cursor,
  # oldest first. The panel cannot learn these any other way: its account
  # cannot read a deleted post, its versions, or the mod log rows naming one.
  # `cursor` is the last row's id older than SETTLE, to pass back as
  # `since`; `more` says a full page was answered and the cursor reached its
  # end. `jailed` is the post's state NOW, so a jailing already released or
  # undone is not listed as standing.
  def index
    jail_panel_only!

    since = params[:since].to_i
    rows = ModAction.where(category: :post_jail, subject_type: "Post", creator: User.system)
                    .where("mod_actions.id > ?", since).order(:id).limit(EVENTS_PER_PAGE).to_a
    posts = Post.where(id: rows.map(&:subject_id)).index_by(&:id)
    events = rows.filter_map do |row|
      post = posts[row.subject_id]
      next if post.nil?

      reason = row.description.delete_prefix("jailed post ##{post.id}, reason: ")
      # The actor kind, from the reason. Only code writes these rows, as the
      # system user, so the set is closed: the pill's jail-on, the
      # banished-tag failsafe, and any other way into the jail
      # (Post#report_jailing_entered, FourierPastJailings), "booru user".
      actor, moderator = case reason
      when /\A#{Regexp.escape(Post::JAIL_DELETION_REASON)}moderator (\S+), from the post page\z/o then ["pill moderator", $1]
      when "#{Post::JAIL_DELETION_REASON}banished tag" then ["banished tag", nil]
      when /\A#{Regexp.escape(Post::JAIL_DELETION_REASON)}(\S+) (?:tagged a deleted post|deleted a post tagged) /o then ["booru user", $1]
      else ["booru user", nil]
      end
      {
        id: row.id, post_id: post.id, md5: post.md5, reason: reason,
        actor: actor, moderator: moderator,
        at: row.created_at.iso8601, tags: post.tag_string,
        jailed: post.jailed?, deleted: post.is_deleted?, hold: post.legal_hold?,
      }
    end
    settled = rows.take_while { |row| row.created_at <= SETTLE.ago }
    cursor = settled.last&.id || since
    render json: { events: events, cursor: cursor, more: rows.size == EVENTS_PER_PAGE && settled.size == rows.size }
  end

  def create
    jail_panel_only!

    # 422, not 404, for a malformed md5. A 404 from this route has to mean one
    # thing only -- "this booru has no release endpoint" -- so the caller can
    # tell an undeployed fork from a bad request without guessing.
    md5 = params[:md5].to_s
    unless md5.match?(/\A[0-9a-f]{32}\z/)
      return render json: { released: false, reason: "md5 must be 32 hex characters" }, status: 422
    end

    # Post.find_by, NOT a tag search: the model has no opinion about who may
    # see the post, which is why the search route could not see these and
    # this one can. A missing post is reported in the BODY, not as a 404, so
    # "no such image" never looks like "no release endpoint".
    post = Post.find_by(md5: md5)
    if post.nil?
      return render json: { released: false, reason: "no such post" }, status: 200
    end

    # The verdict and the write under ONE lock: decided outside it, a
    # moderator's deletion landing between the two would be undone by a
    # verdict about the deletion before it.
    status, body = post.with_lock { decide!(post) }
    render json: body.merge(post_id: post.id), status: status
  end

  private

  def jail_panel_only!
    names = Array(Danbooru.config.fourier_jail_release_names).map { |name| name.to_s.downcase }
    unless CurrentUser.user.is_approver? && names.include?(CurrentUser.user.name.to_s.downcase)
      raise User::PrivilegeError, "The troll jail is released from the jail panel (fourier-sampling) alone: only #{names.join(", ").presence || "nobody"} may call this, as Danbooru.config.fourier_jail_release_names says. Unjail the image in the jail panel."
    end
    skip_authorization # gated on the jail panel's account above
  end

  # [status, body] for a post read under the lock, acting as it says.
  def decide!(post)
    tagged = post.has_tag?(JAIL_TAG)
    if post.legal_hold?
      return [422, { released: false, reason: A_LEGAL_HOLD, deleted: post.is_deleted?, jailed: tagged || post.jailed?, hold: true }]
    end
    unless post.is_deleted?
      # Idempotent on purpose: a retry of a release that already landed must
      # not look like a failure, or the caller retries forever -- so a live
      # post the jail once deleted is "already active". A live post still
      # carrying the tag (an older release that left the untag to the caller)
      # is untagged, which finishes the release. A live post the jail never
      # touched is "not jailed".
      return [422, { released: false, reason: "not jailed", deleted: false, jailed: false }] unless tagged || Post.jail_deletions.exists?(subject_id: post.id)

      untag!(post) if tagged
      return [200, { released: false, reason: "already active" }]
    end

    if post.deletion_is_the_jails?
      release!(post)
      [200, { released: true }]
    else
      # Another account's deletion: the jail's part is lifted -- the tag, and
      # a reported jailing standing on that deletion, closed on the booru's
      # log (post_unjail) -- and that deletion stands.
      untag!(post) if tagged
      ModAction.log("unjailed post ##{post.id}, its other deletion left standing", :post_unjail, subject: post, user: CurrentUser.user) if post.jailing_stands?
      [422, { released: false, reason: NOT_THE_JAILS, deleted: true, jailed: false }]
    end
  end

  # What PostApproval#approve_post does, minus the approval record it cannot
  # create, plus the untag: one save, so undeleted and untagged land together
  # or not at all. Same ModAction as an approval's undeletion, which is also
  # what ends the jail's deletion for Post#deletion_is_the_jails?.
  def release!(post)
    post.flags.pending.update!(status: :rejected)
    post.appeals.pending.update!(status: :succeeded)
    post.remove_tag(JAIL_TAG) if post.has_tag?(JAIL_TAG)
    post.update!(approver: CurrentUser.user, is_flagged: false, is_pending: false, is_deleted: false)
    ModAction.log("undeleted post ##{post.id}", :post_undelete, subject: post, user: CurrentUser.user)
  end

  def untag!(post)
    post.remove_tag(JAIL_TAG)
    post.save!
  end
end
