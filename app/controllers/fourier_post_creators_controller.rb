# frozen_string_literal: true

# Records WHO MADE A POST, once (operator ruling 2026-09-29). See
# FourierPostCreator for why this is recorded rather than read off the post's
# tags, and FourierCreatorPrivacy for what the record decides.
#
# POST /fourier/posts/:post_id/creator.json   builder+ (the posting bots)
#   { "mxid": "@alice:41chan.net" }  -- the AUTHENTICATED sender of the event
#   -> 200 { post_id, mxid }   recorded now, or already recorded as this mxid
#   -> 409 { error, fix, reason: "creator_mismatch" }
#                              a different creator is already recorded; it is
#                              never overwritten. `reason` as the generation
#                              endpoint's 409s carry one
#   -> 422 { error, fix }      not an MXID
#   -> 404 { error, fix }      no such post
#
# UNDER /fourier/ on purpose: nginx hands that prefix to fourier-auth, so a
# browser never reaches this, and only a caller on the danbooru container
# itself -- the bots -- can. That keeps a moderator's builder+ account from
# recording themselves as the creator of a post from the site.
class FourierPostCreatorsController < ApplicationController
  # One key, read directly. Wrapping would copy it into a second params key
  # for nothing (FourierGenerationMetadataController has the same line).
  wrap_parameters false
  respond_to :json

  def create
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above, as FourierTagSourcesController is

    post = Post.find_by(id: params[:post_id])
    if post.nil?
      return render json: {
        error: "no post #{params[:post_id].to_s.first(40).inspect}",
        fix: "record the creator after the post exists, with the id the booru returned for it",
      }, status: 404
    end

    mxid = params[:mxid]
    unless FourierPostCreator.valid_mxid?(mxid)
      return render json: {
        error: "mxid must be a Matrix user id (@localpart:server, at most #{FourierPostCreator::MAX_MXID_LENGTH} characters, no spaces or control characters)",
        fix: "send the sender of the Matrix event that posted this image, as @user:server",
      }, status: 422
    end

    record = FourierPostCreator.record!(post, mxid, CurrentUser.user)
    unless FourierPostCreator.same_mxid?(record.mxid, mxid)
      return render json: {
        error: "post #{post.id} already has a different creator on record",
        fix: "a creator is recorded once and never replaced by a re-send; check the post id, and if the recorded creator is wrong, correcting it is an admin's database change",
        reason: "creator_mismatch",
      }, status: 409
    end

    render json: { post_id: post.id, mxid: record.mxid }, status: 200
  end
end
