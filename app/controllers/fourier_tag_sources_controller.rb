# frozen_string_literal: true

# Receives per-tag provenance at post creation and records it in
# the fourier_tag_sources sidecar (the redesigned tag buckets). Builder+ only
# (the posting bots: fourier-sampling and fourier-tunnel).
# POST /fourier/posts/:post_id/tag_sources
#   { creator: [], auto: [], both: [], meta: [], pending: [], spectrum: [], hydra: [] }
# POST /posts/tag_source_models -- model bits only, for posts already recorded.
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

    post = Post.find(params[:post_id])
    sources = params.require(:fourier_tag_source).permit(:replace_creator, creator: [], auto: [], both: [], meta: [], pending: [], oc: [], spectrum: [], hydra: []).to_h
    # replace_creator: a RE-SCAN of the image's own metadata (the tunnel's
    # !rescan). The creator rows this post has are the previous read of the
    # same bytes, so they are dropped before the new read is written; without
    # that, an upsert can only add, and a name the old normaliser mangled
    # would sit beside its corrected self forever.
    replace = ActiveModel::Type::Boolean.new.cast(sources.delete("replace_creator"))
    FourierTagSource.record_partition!(post, sources, CurrentUser.user, replace_creator: replace)
    FourierTagPropagation.fan_out!(post) # single write path -> fan out the public projection

    # Return the PUBLIC-SAFE projection so the caller writes the Matrix state
    # event from the canonical store rather than recomputing it -- private creator
    # tags never leave here.
    render json: {
      post_id: post.id,
      recorded: FourierTagSource.where(post_id: post.id).count,
      projection: FourierTagSource.matrix_projection(post),
    }, status: :ok
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

  # Read the tag buckets for a post. Default is the identity-gated view (creator/mod
  # see private creator tags, everyone else sees public only). `?scope=public`
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
    raise ActiveRecord::RecordNotFound if post.hidden_from_anonymous?(CurrentUser.user)
    raise ActiveRecord::RecordNotFound if post.hidden_as_deleted?(CurrentUser.user)
    payload = if params[:scope] == "public"
                FourierTagSource.matrix_projection(post)
              else
                # The one place the shapes are joined: on the wire, where a
                # reader indexes by key rather than flattening values. Buckets,
                # lamps, categories, rating and a VIEWER-SAFE tag_string, so a
                # client can draw and edit a pool from this one request.
                FourierTagSource.live_read(post, CurrentUser.user)
              end
    render json: payload, status: :ok
  end
end
