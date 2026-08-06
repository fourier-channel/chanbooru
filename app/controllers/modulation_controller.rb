# frozen_string_literal: true

# Serves the Modulation post view as JSON so the redesigned page can move
# post-to-post entirely client-side -- no full document reload. Read-only; the
# tag buckets come from FourierTagSource.for_viewer, so anonymous callers get
# only public tags and the creator-privacy gate is preserved.
class ModulationController < ApplicationController
  respond_to :json

  def show
    skip_authorization
    post = Post.find(params[:post_id])
    component = ModulationPostComponent.new(post: post, viewer: CurrentUser.user, query: params[:q])
    render json: component.payload, status: :ok
  end
end
