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
    render json: component.payload.merge(comments_html: comments_html(post)), status: :ok
  end

  private

  # The comment section travels as rendered HTML rather than as data. It is
  # upstream's own component -- rebuilding comment markup client-side to avoid
  # one string would mean owning comment rendering, moderation affordances and
  # DText output forever, and they would drift.
  #
  # nil (rather than an empty string) when comments are off, so the client can
  # tell "no comments section" from "a section with nothing in it" and leave the
  # server-rendered markup alone.
  def comments_html(post)
    return nil unless Danbooru.config.comments_enabled?.to_s.truthy?

    view_context.render(CommentSectionComponent.new(post: post, current_user: CurrentUser.user))
  end
end
