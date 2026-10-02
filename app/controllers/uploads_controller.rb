# frozen_string_literal: true

class UploadsController < ApplicationController
  respond_to :html, :xml, :json, :js
  skip_before_action :verify_authenticity_token, only: [:create], if: -> { request.xhr? }

  def index
    @mode = params.fetch(:mode, "gallery")

    @defaults = {}
    @defaults[:uploader_id] = params[:user_id]
    @defaults[:status] = "completed" if request.format.html?
    @limit = params.fetch(:limit, CurrentUser.user.per_page).to_i.clamp(0, PostSets::Post::MAX_PER_PAGE)
    @preview_size = params[:size].presence || cookies[:post_preview_size].presence || MediaAssetGalleryComponent::DEFAULT_SIZE

    @uploads = authorize Upload.visible(CurrentUser.user).paginated_search(params, limit: @limit, count_pages: true, defaults: @defaults)
    @uploads = @uploads.includes(:uploader, :posts, upload_media_assets: :media_asset) if request.format.html?

    respond_with(@uploads, include: { upload_media_assets: { include: :media_asset }})
  end

  def show
    @upload = authorize Upload.find(params[:id])
    @preview_size = params[:size].presence || cookies[:post_preview_size].presence || MediaAssetGalleryComponent::DEFAULT_SIZE

    # Fork: only to a post the uploader may see. Bytes held by a hidden post
    # (Post#hidden_from?) get the upload page, as if unposted -- the redirect
    # and its notice named the post.
    posted = @upload.media_assets.first&.post if @upload.media_asset_count == 1
    posted = nil if posted&.hidden_from?(CurrentUser.user)

    if request.format.html? && posted.present?
      flash[:notice] = "Duplicate of post ##{posted.id}"
      redirect_to posted
    elsif request.format.html? && @upload.media_asset_count > 1
      redirect_to [@upload, UploadMediaAsset]
    elsif @upload.media_asset_count == 1
      @upload_media_asset = @upload.upload_media_assets.first
      @post = Post.new_from_upload(@upload_media_asset, add_artist_tag: true, source: @upload_media_asset.canonical_url, **permitted_attributes(Post).to_h.symbolize_keys)
      respond_with(@upload, include: { upload_media_assets: { include: { media_asset: { include: :post }}}})
    else
      respond_with(@upload, include: { upload_media_assets: { include: { media_asset: { include: :post }}}})
    end
  end

  def new
    @upload = authorize Upload.new(uploader: CurrentUser.user, source: params[:url], referer_url: params[:ref], **permitted_attributes(Upload))
    respond_with(@upload)
  end

  def create
    @upload = authorize Upload.new(uploader: CurrentUser.user, **permitted_attributes(Upload))
    @upload.save
    respond_with(@upload, include: { upload_media_assets: { include: { media_asset: { include: :post }}}})
  end
end
