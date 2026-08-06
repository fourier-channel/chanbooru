# frozen_string_literal: true

# Creator Gallery: a user's individualized presentation page. Reads are public;
# ALL writes are gated to the page's Matrix identity (via FourierIdentity) or an
# admin. A non-admin can only ever create/edit the page matching their own
# verified MXID.
class CreatorGalleriesController < ApplicationController
  layout "sidebar"

  before_action :load_gallery, only: %i[show edit update add_post remove_post create_message destroy_message]
  before_action :require_owner!, only: %i[edit update add_post remove_post create_message destroy_message]

  def index
    skip_authorization
    @galleries = CreatorGallery.order(updated_at: :desc).limit(60)
  end

  def show
    skip_authorization
  end

  def new
    skip_authorization
    @gallery = CreatorGallery.new
  end

  # Claim your page. A non-admin may only create the gallery for their own
  # verified identity; an admin may pass an explicit matrix_id.
  def create
    skip_authorization
    mxid = FourierIdentity.current(request)
    if mxid.blank? && CurrentUser.user.is_admin?
      mxid = params.dig(:creator_gallery, :matrix_id).to_s.strip
    end
    raise User::PrivilegeError, "Sign in with your Matrix identity to create a page." if mxid.blank?

    @gallery = CreatorGallery.new(gallery_params)
    @gallery.assign_attributes(matrix_id: mxid, slug: slug_from(mxid), user_id: CurrentUser.user.id)
    if @gallery.save
      redirect_to creator_gallery_path(@gallery)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    skip_authorization
  end

  def update
    skip_authorization
    if @gallery.update(gallery_params)
      redirect_to creator_gallery_path(@gallery)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # --- curated posts ---
  def add_post
    skip_authorization
    post = Post.find(params[:post_id])
    next_pos = (@gallery.creator_gallery_posts.maximum(:position) || 0) + 1
    @gallery.creator_gallery_posts.create_or_find_by(post_id: post.id) { |cgp| cgp.position = next_pos }
    respond_change
  end

  def remove_post
    skip_authorization
    @gallery.creator_gallery_posts.where(post_id: params[:post_id]).destroy_all
    respond_change
  end

  # --- blog messages ---
  def create_message
    skip_authorization
    @gallery.creator_gallery_messages.create(body: params.require(:creator_gallery_message).permit(:body)[:body])
    respond_change
  end

  def destroy_message
    skip_authorization
    @gallery.creator_gallery_messages.where(id: params[:message_id]).destroy_all
    respond_change
  end

  private

  def load_gallery
    @gallery = CreatorGallery.find_by!(slug: params[:slug])
  end

  # The write gate: the request's VERIFIED Matrix identity must match this page's
  # owner, or the current Danbooru user must be an admin.
  def require_owner!
    return if FourierIdentity.matches?(request, @gallery.matrix_id)
    return if CurrentUser.user.is_admin?

    raise User::PrivilegeError, "This page can only be edited by its Matrix owner."
  end

  def gallery_params
    params.fetch(:creator_gallery, {}).permit(:title, :bio, :style, :matrix_contact)
  end

  def slug_from(mxid)
    mxid.to_s.sub(/\A@/, "").split(":").first
  end

  def respond_change
    respond_to do |format|
      format.html { redirect_to edit_creator_gallery_path(@gallery) }
      format.json { render json: { ok: true, posts: @gallery.creator_gallery_posts.count, messages: @gallery.creator_gallery_messages.count } }
    end
  end
end
