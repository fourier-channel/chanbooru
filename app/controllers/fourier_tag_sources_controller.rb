# frozen_string_literal: true

# Receives per-tag provenance from fourier-bmb at post creation and records it in
# the fourier_tag_sources sidecar (the redesigned tag buckets). Builder+ only
# (the bmb bot). POST /fourier/posts/:post_id/tag_sources
#   { creator: [], auto: [], both: [], meta: [], pending: [] }
class FourierTagSourcesController < ApplicationController
  wrap_parameters :fourier_tag_source, include: %i[creator auto both meta pending]
  respond_to :json

  def create
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above, not a per-record Pundit policy

    post = Post.find(params[:post_id])
    sources = params.require(:fourier_tag_source).permit(creator: [], auto: [], both: [], meta: [], pending: []).to_h
    FourierTagSource.record_partition!(post, sources, CurrentUser.user)
    FourierTagPropagation.fan_out!(post) # single write path -> fan out the public projection

    # Return the PUBLIC-SAFE projection so the caller (bmb) writes the Matrix state
    # event from the canonical store rather than recomputing it -- private creator
    # tags never leave here.
    render json: {
      post_id: post.id,
      recorded: FourierTagSource.where(post_id: post.id).count,
      projection: FourierTagSource.matrix_projection(post),
    }, status: :ok
  end

  # Read the tag buckets for a post. Default is the identity-gated view (creator/mod
  # see private creator tags, everyone else sees public only). `?scope=public`
  # returns the machine-facing public projection unconditionally -- used by bmb to
  # refresh a duplicate image's Matrix state without leaking private tags.
  def show
    skip_authorization
    post = Post.find(params[:post_id])
    payload = params[:scope] == "public" ? FourierTagSource.matrix_projection(post) : FourierTagSource.for_viewer(post, CurrentUser.user)
    render json: payload, status: :ok
  end
end
