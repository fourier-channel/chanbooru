# frozen_string_literal: true

# Releasing an image from fourier-sampling's troll jail.
#
# Jailing an image deletes its booru post; releasing it is supposed to bring
# the post back. It did not, and could not, for two independent reasons -- both
# measured against production on 2026-09-06:
#
#   1. fourier-sampling finds a post by searching `md5:<hash>`, and the search
#      index hides deleted posts from anyone below deleted_post_visibility_level
#      (ADMIN). The sampling bot is an Approver, so the lookup returned nothing
#      and the release gave up before it ever tried to undelete. All three of
#      `md5:x`, `md5:x status:any` and `md5:x status:deleted` came back empty.
#
#   2. Even with the id in hand, POST /post_approvals.json refuses: undeleting
#      is approving, and PostApproval rejects approving your own upload unless
#      you are an admin. The bot uploaded all 3,195 jailed posts, so it was
#      structurally incapable of undoing its own deletions. Verified live --
#      HTTP 422, "You cannot approve a post you uploaded".
#
# The bot could delete but not undelete. That asymmetry is the bug.
#
# Three fixes were possible and two were rejected:
#
#   - Raise the bot to ADMIN. Fixes both in one line and hands an account whose
#     API key sits in a file on a scraping box the run of the site.
#   - Relax PostApprovalPolicy#can_approve_own_uploads?. Upstream's rule, and it
#     guards a real case (self-approving a pending upload into the index).
#     Widening it would also let any approver undo a moderator's deletion of
#     their own post.
#   - This: one verb, additive, fork-local, that can ONLY reverse a jailing.
#
# The narrowness is the whole design. It refuses unless the post is deleted AND
# carries the jail tag, so the only deletions it can undo are the ones the jail
# performed. A moderator's deletion of an ordinary post is not reachable
# through here, whoever calls it.
class FourierJailController < ApplicationController
  respond_to :json

  # Kept in step with fourier-sampling's JAIL_TAG (src/booru/jailSync.ts). If
  # these two ever disagree, release stops working and says so with a 422
  # rather than quietly restoring the wrong thing.
  JAIL_TAG = "troll_jail"

  def create
    raise User::PrivilegeError unless CurrentUser.user.is_approver?
    skip_authorization # gated on is_approver? plus the jail-tag check below

    # 422, not 404, for a malformed md5. A 404 from this route has to mean one
    # thing only -- "this booru has no release endpoint" -- so the caller can
    # tell an undeployed fork from a bad request without guessing.
    md5 = params[:md5].to_s
    unless md5.match?(/\A[0-9a-f]{32}\z/)
      return render json: { released: false, reason: "md5 must be 32 hex characters" }, status: :unprocessable_entity
    end

    # Post.find_by, NOT a tag search: the model has no opinion about
    # deleted_post_visibility_level, which is exactly why the search route
    # could not see these and this one can.
    # A missing post is reported in the BODY, not as a 404. The caller has to
    # be able to tell "this booru has no such image" from "this booru does not
    # have the release endpoint yet", and both would be a bare 404.
    post = Post.find_by(md5: md5)
    if post.nil?
      return render json: { released: false, reason: "no such post" }, status: :ok
    end

    unless post.tag_array.include?(JAIL_TAG)
      return render json: { post_id: post.id, released: false, reason: "not jailed" }, status: :unprocessable_entity
    end

    unless post.is_deleted?
      # Idempotent on purpose. A retry after a half-finished release must not
      # look like a failure, or the caller will keep retrying forever.
      return render json: { post_id: post.id, released: false, reason: "already active" }, status: :ok
    end

    undelete!(post)
    render json: { post_id: post.id, released: true }, status: :ok
  end

  private

  # What PostApproval#approve_post does, minus the approval record it cannot
  # create. Same field set, same ModAction, so an undeletion from here shows up
  # in the moderation log exactly like any other.
  def undelete!(post)
    post.with_lock do
      post.flags.pending.update!(status: :rejected)
      post.appeals.pending.update!(status: :succeeded)
      post.update!(approver: CurrentUser.user, is_flagged: false, is_pending: false, is_deleted: false)
      ModAction.log("undeleted post ##{post.id}", :post_undelete, subject: post, user: CurrentUser.user)
    end
  end
end
