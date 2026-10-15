# frozen_string_literal: true

# Receives per-tag provenance at post creation and records it in
# the fourier_tag_sources sidecar (the redesigned tag buckets). Builder+ only
# (the posting bots: fourier-sampling and fourier-tunnel).
# POST /fourier/posts/:post_id/tag_sources
#   { creator: [], auto: [], both: [], meta: [], pending: [], spectrum: [], hydra: [] }
# POST /posts/tag_source_models -- model bits only, for posts already recorded.
#
# GATE 3 FOR POSTS, piece B (fourier-basis docs/design/GATE3_MATRIX_POSTS.md):
# create also takes an optional "mxc" -- another address of the post's image,
# a re-upload of the same bytes the tunnel mapped to the post by md5 -- and
# records it (PostMxc, 'alias'), answering {"mxc": {"accepted": true}} or
# {"mxc": {"accepted": false, "reason": "no_such_post"|"mxc_mapped_elsewhere"}}.
# A body carrying ONLY the mxc (the tunnel's duplicate path) changes no tag.
# Without an mxc the route answers exactly as before.
class FourierTagSourcesController < ApplicationController
  # EVERY key create permits must be listed here too. A JSON body's top-level
  # keys reach params[:fourier_tag_source] only if they are wrapped, and
  # spectrum and hydra were not: the lamp's model bits were dropped for every
  # post from the day the lamp shipped (2026-09-20) until 2026-09-24.
  wrap_parameters :fourier_tag_source, include: %i[creator auto both meta pending oc spectrum hydra replace_creator]
  respond_to :json

  def create
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above, not a per-record Pundit policy

    return create_with_mxc if params.key?(:mxc)

    post = Post.find(params[:post_id])
    # A post carrying a flagged tag (TagQuarantine) exists for a posting bot
    # only when the bot uploaded it: its own tagging keeps working, another
    # account's flagged post answers as a missing one.
    raise ActiveRecord::RecordNotFound if post.hidden_as_flagged?(CurrentUser.user)
    render json: record_tag_sources(post), status: 200
  end

  # POST /posts/tag_source_models
  #   { posts: [{ post_id: 1, spectrum: [...], hydra: [...] }, ...] }   1 to 100 posts
  #
  # Which model reported each tag, for posts that already exist. The retag
  # timer in fourier-sampling adds hydra's tags to old posts, and create is no
  # way to say which model found them: it re-files buckets. This route ONLY
  # ORs model bits in (the rules are on FourierTagSource.record_models!), so
  # sending the same body again changes nothing.
  #
  # Reads params[:posts] directly rather than through permit: nothing here is
  # mass-assigned, and this app answers an unpermitted key with a 403, which
  # would make a malformed body look like a refused login.
  def models
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above, as create is

    entries = params[:posts]
    limit = FourierTagSource::MAX_MODEL_POSTS
    unless entries.is_a?(Array) && entries.size.between?(1, limit) && entries.all?(ActionController::Parameters)
      return render json: {
        error: "posts must be a list of 1 to #{limit} objects",
        fix: "send {\"posts\": [{\"post_id\": 123, \"spectrum\": [...], \"hydra\": [...]}]}, split into batches of #{limit}",
      }, status: 422
    end

    bad = entries.find { |e| Integer(e[:post_id].to_s, 10, exception: false).nil? }
    if bad
      return render json: {
        error: "post_id must be an integer, got #{bad[:post_id].inspect}",
        fix: "send each post's numeric booru id as post_id",
      }, status: 422
    end

    parsed = entries.map do |e|
      { post_id: e[:post_id].to_s.to_i, spectrum: Array(e[:spectrum]).map(&:to_s), hydra: Array(e[:hydra]).map(&:to_s) }
    end
    render json: FourierTagSource.record_models!(parsed, CurrentUser.user), status: 200
  end

  # Read the tag buckets for a post. Default is the identity-gated view (the
  # post's creator sees its private creator tags -- FourierCreatorPrivacy --
  # and everyone else, moderators and admins included, sees public only). `?scope=public`
  # returns the machine-facing public projection whoever asks -- used by a bot to
  # refresh a duplicate image's Matrix state without leaking private tags -- for
  # any post the caller may see at all (below).
  def show
    skip_authorization
    post = Post.find(params[:post_id])
    # The doors PostsController#show shuts, shut here too, by either scope:
    # a deleted post answers nothing -- "not the page, not the tags, not the
    # id" -- and a gated post does not exist for a signed-out caller. This
    # read answered both until 2026-09-24: a jailed post's whole tag list, to
    # anyone. 404 as there, which every reader already takes as "no such post".
    # One rule, Post#hidden_from?: gated, deleted or jailed, under a hidden creator prefix, hidden by its creator.
    raise ActiveRecord::RecordNotFound if post.hidden_from?(CurrentUser.user)
    payload = if params[:scope] == "public"
                FourierTagSource.matrix_projection(post)
              else
                # The one place the shapes are joined: on the wire, where a
                # reader indexes by key rather than flattening values. Buckets,
                # lamps, categories, rating and a VIEWER-SAFE tag_string, so a
                # client can draw and edit a pool from this one request.
                FourierTagSource.live_read(post, CurrentUser.user, request: request)
              end
    render json: payload, status: :ok
  end

  private

  # create, carrying an mxc (see the header). A missing post -- or one
  # carrying a flagged tag the bot did not upload, which answers as missing
  # -- records nothing: 200 with no_such_post for an mxc-only body, the
  # route's own 404 (with the mxc's outcome) when a tag partition was sent,
  # since those tags were not recorded either.
  def create_with_mxc
    mxc = params[:mxc].to_s
    unless mxc.match?(MatrixMedia::MXC)
      return render json: { error: "mxc must be mxc://<server>/<media id>, got #{mxc.truncate(80).inspect}", fix: "send the re-upload's own mxc:// URI as \"mxc\"" }, status: 422
    end

    partition = params[:fourier_tag_source].present?
    post = Post.find_by(id: params[:post_id].to_s)
    if post.nil? || post.hidden_as_flagged?(CurrentUser.user)
      outcome = { accepted: false, reason: "no_such_post" }
      return render json: { success: false, error: "ActiveRecord::RecordNotFound", message: "That record was not found.", mxc: outcome }, status: 404 if partition

      return render json: { post_id: params[:post_id].to_i, mxc: outcome }, status: 200
    end

    body = partition ? record_tag_sources(post) : { post_id: post.id }
    result = PostMxc.record_alias!(post, mxc)
    body[:mxc] = (result == :accepted) ? { accepted: true } : { accepted: false, reason: result.to_s }
    render json: body, status: 200
  end

  def record_tag_sources(post)
    sources = params.require(:fourier_tag_source).permit(:replace_creator, creator: [], auto: [], both: [], meta: [], pending: [], oc: [], spectrum: [], hydra: []).to_h
    # replace_creator: a RE-SCAN of the image's own metadata (the tunnel's
    # !rescan). The creator rows this post has are the previous read of the
    # same bytes, so they are dropped before the new read is written; without
    # that, an upsert can only add, and a name the old normaliser mangled
    # would sit beside its corrected self forever.
    replace = ActiveModel::Type::Boolean.new.cast(sources.delete("replace_creator"))
    not_declared = FourierTagSource.record_partition!(post, sources, CurrentUser.user, replace_creator: replace)
    FourierTagPropagation.fan_out!(post) # single write path -> fan out the public projection

    # Return the PUBLIC-SAFE projection so the caller writes the Matrix state
    # event from the canonical store rather than recomputing it -- private creator
    # tags never leave here. A name in `oc` the hub refused to declare is
    # named with why, never dropped in silence (FourierTagSource.
    # record_partition!): a name sent in `oc` alone -- the tunnel's "the
    # poster's own" -- that the recorded creator's rule does not pass, or the
    # recorded creator's own name that fails it. A name OFFERED (in `oc` and
    # the creator lists) that is neither the recorded creator's own nor an
    # established original character is not a refusal and is not named: it
    # stays the private creator row the tunnel also sent it as.
    {
      post_id: post.id,
      recorded: FourierTagSource.where(post_id: post.id).count,
      projection: FourierTagSource.matrix_projection(post),
      original_characters_not_declared: not_declared.presence,
    }.compact
  end
end
