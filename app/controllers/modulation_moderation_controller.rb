# frozen_string_literal: true

# The post page's moderation pill: ( jail | delete ), two switches with one
# rule between them. Operator, 2026-09-19:
#
#   click on delete -> delete lights up, jail does not change.
#   click on jail   -> both jail and delete light up.
#   delete cannot be disabled while jailed is true, but jailed can be
#   disabled while still leaving the post deleted.
#
# JAILED IMPLIES DELETED; DELETED DOES NOT IMPLY JAILED. "Delete" here is
# Danbooru's flag under this fork's safeguards: the post disappears from every
# surface and can be restored at any time (the bytes are untouched). "Jail" is
# the troll_jail tag, fourier-sampling's verdict on an image, and this is the
# first place the booru itself can set or clear it.
#
# The client sends the state it WANTS for one switch; this action works out
# the transition, refuses the one the rule forbids, and answers with the
# state the post is actually in. It never guesses: every branch reads the post
# again under its lock before acting.
#
# WHAT EACH TRANSITION IS, in Danbooru's own terms, so nothing here invents a
# second way to do a thing the booru already does:
#   delete on    Post#delete!(reason) -- the flag, a deletion PostFlag, ModAction
#   delete off   PostApproval.create! -- approving is undeleting, with upstream's
#                own refusals (own upload, approved twice) reported verbatim
#   jail on      the tag, then delete on if the post is active
#   jail off     the tag only; the post stays deleted, per the rule
#
# NOT /fourier_jail/release. Release is the jail's OWN verb -- undelete AND
# hand back -- written for sampling, which cannot undelete its own uploads.
# Unjailing here deliberately leaves the post deleted, so it is a different
# act with a different name, and release keeps its narrow predicate.
class ModulationModerationController < ApplicationController
  respond_to :json

  def update
    post = Post.find(params[:post_id])
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
        if want["jail"] && !post.has_tag?(jail_tag)
          post.add_tag(jail_tag)
          post.save!
          post.delete!("troll jail: moderator, from the post page", user: CurrentUser.user) unless post.is_deleted?
        elsif !want["jail"] && post.has_tag?(jail_tag)
          post.remove_tag(jail_tag)
          post.save!
        end
      end
      if want.key?("deleted")
        if want["deleted"] && !post.is_deleted?
          post.delete!("deleted from the post page", user: CurrentUser.user)
        elsif !want["deleted"] && post.is_deleted?
          if post.has_tag?(jail_tag)
            refused = "a jailed post stays deleted; unjail it first"
          else
            approval = PostApproval.new(post: post, user: CurrentUser.user)
            refused = approval.errors.full_messages.join("; ") unless approval.save
          end
        end
      end
    end

    post.reload
    state = { jailed: post.has_tag?(jail_tag), deleted: post.is_deleted?, can: true }
    if refused
      render json: state.merge(refused: refused), status: :unprocessable_entity
    else
      render json: state, status: :ok
    end
  end
end
