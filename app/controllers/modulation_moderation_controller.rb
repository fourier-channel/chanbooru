# frozen_string_literal: true

# The post page's moderation pill: ( jail | delete ), two switches with one
# rule between them. Operator, 2026-09-19:
#
#   click on delete -> delete lights up, jail does not change.
#   click on jail   -> both jail and delete light up.
#   delete cannot be disabled while jailed is true
#
# JAILED IMPLIES DELETED; DELETED DOES NOT IMPLY JAILED. "Delete" here is
# Danbooru's flag under this fork's safeguards: the post disappears from every
# surface and can be restored at any time (the bytes are untouched). "Jail" is
# the troll_jail tag, fourier-sampling's verdict on an image (operator ruling
# 2026-10-10: "Jailed means deleted" -- a jailed post is a deleted post
# carrying the tag, and is seen exactly as any deleted post is).
#
# ONE WAY ONLY, INTO THE JAIL. Operator ruling 2026-10-09: there is no
# booru-side way to release a jailed post; release happens only from the jail
# panel (POST /fourier_jail/release by the jail's account). So on a jailed
# post (Post#jailed?) jail-off and delete-off are refused with a message that
# names the panel. Until then the pill's jail-off took the tag off and left
# the post deleted, and four production posts are stuck that way (90197,
# 119048, 104280, 89787): sampling's record still holds them jailed, and only
# the release route can finish them.
#
# The client sends the state it WANTS for one switch; this action works out
# the transition, refuses the ones the rules forbid, and answers with the
# state the post is actually in. It never guesses: every branch reads the post
# again under its lock before acting.
#
# WHAT EACH TRANSITION IS, in Danbooru's own terms:
#   delete on    Post#delete!(reason) -- the flag, a deletion PostFlag, ModAction
#   delete off   PostApproval.create! -- approving is undeleting, with upstream's
#                own refusals (own upload, approved twice) reported verbatim;
#                refused for a jailed post (here, and in PostApproval itself)
#   jail on      Post#jail_by_booru!, then the tag, as the moderator: the
#                deletion (if the post is live) made by the system user on the
#                moderator's behalf, so the release route can prove it is the
#                jail's (it proves a jailing by who deleted, never by words),
#                and the post_jail row that reports it to the jail panel
#                (operator 2026-10-09: every booru-side jailing reaches the
#                panel)
#   jail off     refused: the jail panel releases
class ModulationModerationController < ApplicationController
  respond_to :json

  def update
    # find_writable!: the pill jails and deletes posts the moderator cannot
    # see, but never one its creator hid from them, whose state it would
    # otherwise report (Q2, 2026-10-08).
    post = Post.find_writable!(params[:post_id])
    authorize post, :moderate? # an unbanned approver; PostPolicy#moderate? says why not delete?
    jail_tag = Danbooru.config.troll_jail_tag

    # slice first: the route's post_id and the wrapped modulation_moderation key
    # ride along, and this app raises on an unpermitted parameter rather than
    # dropping it -- every click was a 403 until this was measured.
    want = params.slice(:jail, :deleted).permit(:jail, :deleted).to_h.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) }
    refused = nil

    post.with_lock do
      post.reload
      if want.key?("jail")
        if want["jail"] && !post.jailed?
          # The jailing first, the tag after: the tag then lands on a post
          # whose jailing is already reported, so the save that adds it has
          # nothing to report again (Post#report_jailing_entered).
          post.jail_by_booru!("#{Post::JAIL_DELETION_REASON}moderator #{CurrentUser.user.name}, from the post page")
          unless post.has_tag?(jail_tag)
            post.add_tag(jail_tag)
            post.save!
          end
        elsif !want["jail"] && (post.jailed? || post.has_tag?(jail_tag))
          refused = post.jailed? ? post.jail_release_refusal : Post::JAILED_RELEASE_DOOR
        end
      end
      if want.key?("deleted") && refused.nil?
        if want["deleted"] && !post.is_deleted?
          post.delete!("deleted from the post page", user: CurrentUser.user)
        elsif !want["deleted"] && post.is_deleted?
          if post.jailed?
            refused = post.jail_release_refusal
          else
            approval = PostApproval.new(post: post, user: CurrentUser.user)
            refused = approval.errors.full_messages.join("; ") unless approval.save
          end
        end
      end
    end

    post.reload
    state = { jailed: post.jailed? || post.has_tag?(jail_tag), deleted: post.is_deleted?, can: true }
    if refused
      render json: state.merge(refused: refused), status: :unprocessable_entity
    else
      render json: state, status: :ok
    end
  end
end
