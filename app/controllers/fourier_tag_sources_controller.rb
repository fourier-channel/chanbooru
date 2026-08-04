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

    render json: { post_id: post.id, recorded: FourierTagSource.where(post_id: post.id).count }, status: :ok
  end
end
