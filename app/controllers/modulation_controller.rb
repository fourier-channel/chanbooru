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
    # The same two doors PostsController#show shuts, shut here for the same
    # reason it gives: "a deleted post answers nothing, by ANY door." This is a
    # door. It was open, and it answered 200 with status "deleted", the
    # deletion reason ("troll jail: troll"), the tag buckets and the meta --
    # and, for a deleted post carrying no gated tag, the real media src, since
    # Post#visible? never consults is_deleted. Measured against production
    # 2026-09-08 while the HTML page for the same id correctly 404'd.
    #
    # RecordNotFound rather than 403, again for the controller's own reason:
    # "there is something here you may not see" is itself the disclosure, and
    # troll jail exists so that there is nothing to point at.
    raise ActiveRecord::RecordNotFound if post.hidden_from_anonymous?(CurrentUser.user)
    raise ActiveRecord::RecordNotFound if post.hidden_as_deleted?(CurrentUser.user)
    component = ModulationPostComponent.new(post: post, viewer: CurrentUser.user, query: params[:q], settings: ModulationSetting.for_viewer(CurrentUser.user, session))
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

    # Partial lookup follows the REQUEST's format, and this request is JSON --
    # so the comment form partial resolves to a JSON template that does not
    # exist and the whole response 406s. The form only renders for a viewer who
    # may comment, which is why this failed for logged-in users and nobody else:
    # every signed-in reader's client-side navigation would have fallen back to
    # a full page reload.
    #
    # Restored rather than left set: nothing after this renders a template, but
    # a controller that quietly changes its own view lookup for the rest of the
    # action is a trap for the next thing added here.
    previous = lookup_context.formats
    lookup_context.formats = [:html]
    view_context.render(CommentSectionComponent.new(post: post, current_user: CurrentUser.user))
  ensure
    lookup_context.formats = previous if previous
  end
end
