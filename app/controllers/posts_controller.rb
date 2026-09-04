# frozen_string_literal: true

class PostsController < ApplicationController
  respond_to :html, :xml, :json, :js
  layout "sidebar"

  before_action :log_search_query, only: :index
  after_action :log_search_count, only: :index, if: -> { request.format.html? && response.successful? }

  def index
    if params[:md5].present?
      @post = authorize Post.find_by!(md5: params[:md5])
      # Same rule by the other door: an md5 lookup must not confirm a gated post
      # exists when the post page would not.
      raise ActiveRecord::RecordNotFound if @post.hidden_from_anonymous?(CurrentUser.user)
      raise ActiveRecord::RecordNotFound if @post.hidden_as_deleted?(CurrentUser.user)
      respond_with(@post) do |format|
        format.html { redirect_to(@post) }
      end
    elsif params[:random].to_s.truthy?
      # post_query, NOT normalized_query. The normalized one carries the implicit
      # metatags, and stringifying it into a redirect publishes them: a signed-out
      # visitor clicking "Random" got the whole gated tag list in their URL bar,
      # and then blew their own tag limit on the request that followed.
      #
      # Nothing is lost by dropping them here. The redirect target rebuilds a
      # PostSet, which applies the implicit metatags again -- so the random pick
      # is still made over the filtered set.
      query = "#{post_set.post_query} random:#{post_set.per_page}".strip
      authorize Post
      redirect_to posts_path(tags: query, page: params[:page], limit: params[:limit], format: request.format.symbol)
    else
      @posts = authorize post_set.posts, policy_class: PostPolicy
      @preview_size = params[:size].presence || cookies[:post_preview_size].presence || PostGalleryComponent::DEFAULT_SIZE
      raise PageRemovedError if request.format.html? && post_set.banned_artist?

      respond_with(@posts) do |format|
        format.atom
      end
    end
  end

  def show
    @post = authorize Post.eager_load(:uploader, :media_asset).find(params[:id])
    # Gated content does not exist for a signed-out visitor, including by direct
    # link. RecordNotFound rather than a 403: telling someone "there is something
    # here you may not see" is itself a disclosure, and for the tags on this list
    # it is the one kind of disclosure most worth not making. A 404 says only
    # what a 404 says.
    raise ActiveRecord::RecordNotFound if @post.hidden_from_anonymous?(CurrentUser.user)
    # A deleted post answers nothing, by any door. Same 404 rather than a 403,
    # for the same reason: "there is something here you may not see" is itself
    # the disclosure, and troll jail exists so that there is nothing to point at.
    raise ActiveRecord::RecordNotFound if @post.hidden_as_deleted?(CurrentUser.user)
    raise PageRemovedError if request.format.html? && !request.variant.tooltip? && @post.banblocked?(CurrentUser.user)

    if request.format.html?
      include_deleted = @post.is_deleted? || (@post.parent_id.present? && @post.parent.is_deleted?) || CurrentUser.user.show_deleted_children?
      @sibling_posts = @post.parent.present? ? @post.parent.children : Post.none
      @sibling_posts = @sibling_posts.undeleted unless include_deleted
      @sibling_posts = @sibling_posts.includes(:media_asset)

      @child_posts = @post.children
      @child_posts = @child_posts.undeleted unless include_deleted
      @sibling_posts = @sibling_posts.includes(:media_asset)
    end

    respond_with(@post) do |format|
      format.html.tooltip { render layout: false }
    end
  end

  def show_seq
    authorize Post
    context = PostSearchContext.new(params)
    if context.post_id
      redirect_to(post_path(context.post_id, q: params[:q]))
    else
      redirect_to(post_path(params[:id], q: params[:q]))
    end
  end

  def create
    @upload_media_asset = UploadMediaAsset.find(params[:upload_media_asset_id])
    @post = authorize Post.new_from_upload(@upload_media_asset, **permitted_attributes(Post).to_h.symbolize_keys)
    @post.save_if_unique(:md5)

    if @post.errors.none?
      notice = @post.warnings.full_messages.join(".\n \n") if @post.warnings.any?
      respond_with(@post, notice: notice)
    elsif @post.errors.of_kind?(:md5, :taken)
      @original_post = Post.find_by!(md5: @post.md5)
      @original_post.update(rating: @post.rating.presence || @original_post.rating, parent_id: @post.parent_id || @original_post.parent_id, tag_string: "#{@original_post.tag_string} #{params.dig(:post, :tag_string)}")
      flash[:notice] = "Duplicate of post ##{@original_post.id}; merging tags"
      redirect_to @original_post
    else
      @post.tag_string = params.dig(:post, :tag_string) # Preserve original tag string on validation error
      respond_with(@post, render: { template: "upload_media_assets/show" })
    end
  end

  def update
    @post = authorize Post.find(params[:id])
    @post.update(permitted_attributes(@post))
    @show_votes = (params[:show_votes].presence || cookies[:post_preview_show_votes].presence || "false").truthy?
    @preview_size = params[:size].presence || cookies[:post_preview_size].presence || PostGalleryComponent::DEFAULT_SIZE
    respond_with_post_after_update(@post)
  end

  def destroy
    @post = authorize Post.find(params[:id])

    if params[:commit] == "Delete"
      move_favorites = params.dig(:post, :move_favorites).to_s.truthy?
      @post.delete!(params.dig(:post, :reason), move_favorites: move_favorites, user: CurrentUser.user)
      flash[:notice] = "Post deleted"
    end

    respond_with_post_after_update(@post)
  end

  def revert
    @post = authorize Post.find(params[:id])
    @version = @post.versions.find(params[:version_id])
    @post.revert_to!(@version)

    respond_with(@post) do |format|
      format.js
    end
  end

  def copy_notes
    @post = Post.find(params[:id])
    @other_post = authorize Post.find(params[:other_post_id].to_i)
    @post.copy_notes_to(@other_post)

    if @post.errors.any?
      @error_message = @post.errors.full_messages.join("; ")
      render json: { success: false, reason: @error_message }.to_json, status: 400
    else
      head 204
    end
  end

  def random
    @post = Post.user_tag_match(params[:tags]).random(1).take
    authorize @post, policy_class: PostPolicy

    raise ActiveRecord::RecordNotFound if @post.nil?
    respond_with(@post) do |format|
      format.html { redirect_to post_path(@post, q: params[:tags]) }
    end
  end

  def mark_as_translated
    @post = authorize Post.find(params[:id])
    @post.mark_as_translated(params[:post])
    respond_with_post_after_update(@post)
  end

  private

  def post_set
    @post_set ||= begin
      tag_query = params[:tags] || params.dig(:post, :tags)
      tag_query = apply_modulation_panel_memory(tag_query)
      show_votes = (params[:show_votes].presence || cookies[:post_preview_show_votes].presence || "false").truthy?
      PostSets::Post.new(tag_query, params[:page], params[:limit], format: request.format.symbol, show_votes: show_votes)
    end
  end

  # fourier: the Modulation search panel retains its settings server-side and
  # does not reset between searches (operator ruling 2026-09-04). An explicit
  # order: in the query IS the panel being set, so it is recorded; a query
  # without one gets the remembered sort re-applied. sort_reset clears the
  # memory (the blank select option), show_deleted=1/0 sets the deleted
  # toggle, and a remembered deleted toggle widens a status-less query to
  # status:any. HTML + Modulation only: the API sees exactly what it asked.
  def apply_modulation_panel_memory(tag_query)
    return tag_query unless request.format.html? && modulation? && action_name == "index" && params[:random].blank?

    if params[:show_deleted].present?
      ModulationSetting.record!(CurrentUser.user, session, { "gallery_show_deleted" => params[:show_deleted] })
    end
    ModulationSetting.record!(CurrentUser.user, session, { "gallery_sort" => "" }) if params[:sort_reset].present?

    query = tag_query.to_s
    settings = ModulationSetting.for_viewer(CurrentUser.user, session)
    explicit_order = query[/\border:(\S+)/i, 1]

    if params[:sort_reset].blank?
      if explicit_order.present?
        ModulationSetting.record!(CurrentUser.user, session, { "gallery_sort" => explicit_order }) if explicit_order != settings["gallery_sort"]
      elsif settings["gallery_sort"].present?
        query = [query.presence, "order:#{settings['gallery_sort']}"].compact.join(" ")
      end
    end

    if settings["gallery_show_deleted"] && !query.match?(/(?:\A|\s)-?status:\S+/i)
      query = [query.presence, "status:any"].compact.join(" ")
    end

    query.presence
  rescue StandardError
    # The panel memory is a convenience; a failure here must degrade to the
    # plain search, never take the index down.
    tag_query
  end

  def log_search_query
    DanbooruLogger.add_attributes("search", {
      query: post_set.normalized_query.to_s,
      page: post_set.current_page,
      limit: post_set.per_page,
      tag_count: post_set.post_query.tag_names.length,
      metatag_count: post_set.post_query.metatags.length,
    })
  end

  def log_search_count
    DanbooruLogger.add_attributes("search", { count: post_set.post_count })
  end

  def respond_with_post_after_update(post)
    respond_with(post) do |format|
      format.html do
        if post.warnings.any?
          flash[:notice] = post.warnings.full_messages.join(".\n \n")
        end

        if post.errors.any?
          flash[:notice] = post.errors.full_messages.join("; ")
        end

        redirect_to post_path(post, { q: params[:q] }.compact_blank)
      end

      format.json do
        render json: post.to_json
      end
    end
  end
end
