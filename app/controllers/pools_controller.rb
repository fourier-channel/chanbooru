# frozen_string_literal: true

class PoolsController < ApplicationController
  respond_to :html, :xml, :json, :js

  def index
    if request.format.html?
      @pools = authorize Pool.paginated_search(params, count_pages: true, defaults: { is_deleted: false })
    else
      @pools = authorize Pool.paginated_search(params, count_pages: true)
    end
    # Fork: which listed post ids are hidden from the viewer, once for the page.
    Pool.preload_visible_post_ids(@pools)

    respond_with(@pools)
  end

  def show
    # Fork: a pool's page is a paged listing of its posts -- members only
    # (MembersOnly; the index is covered by paginated_search).
    MembersOnly.post_listing!(CurrentUser.user)
    limit = params[:limit].presence || CurrentUser.user.per_page

    @pool = authorize Pool.find(params[:id])
    @posts = @pool.posts.paginate(params[:page], limit: limit, count: @pool.post_count)
    respond_with(@pool)
  end

  def new
    @pool = authorize Pool.new(permitted_attributes(Pool))
    respond_with(@pool)
  end

  def edit
    @pool = authorize Pool.find(params[:id])
    respond_with(@pool)
  end

  def gallery
    # Fork: cover posts, paged -- members only (MembersOnly).
    MembersOnly.post_listing!(CurrentUser.user)
    limit = params[:limit].presence || CurrentUser.user.per_page
    search = search_params.presence || ActionController::Parameters.new(category: "series")

    @pools = authorize Pool.search(search, CurrentUser.user).paginate(params[:page], limit: limit, search_count: params[:search])
    Pool.preload_visible_post_ids(@pools)
    respond_with(@pools)
  end

  def create
    @pool = authorize Pool.new(permitted_attributes(Pool))
    @pool.save

    respond_with(@pool, notice: "Pool created")
  end

  def update
    @pool = authorize Pool.find(params[:id])
    attributes = permitted_attributes(@pool)
    @pool.assign_attributes(attributes)
    @pool.keep_unseen_post_ids(CurrentUser.user, named: attributes.key?("post_ids") || attributes.key?("post_ids_string"))
    @pool.save

    respond_with(@pool, notice: "Pool updated")
  end

  def destroy
    @pool = authorize Pool.find(params[:id])
    @pool.update(is_deleted: true)
    @pool.create_mod_action_for_delete

    respond_with(@pool, notice: "Pool deleted")
  end

  def undelete
    @pool = authorize Pool.find(params[:id])
    @pool.update(is_deleted: false)
    @pool.create_mod_action_for_undelete

    respond_with(@pool, notice: "Pool undeleted")
  end

  def revert
    @pool = authorize Pool.find(params[:id])
    @version = @pool.versions.find(params[:version_id])
    # A version's posts that no longer exist for the reverter are left out,
    # counted in a warning (Pool#revert_to!, boo.122 D5). Any other refusal
    # is said as a 422, not the 500 an unrescued RecordInvalid answers.
    begin
      @pool.revert_to!(@version)
    rescue ActiveRecord::RecordInvalid
      return respond_with(@pool)
    end

    notice = ["Pool reverted", *@pool.warnings.full_messages].join(". ")
    respond_with(@pool, notice: notice) do |format|
      format.js
    end
  end

  private

  def item_matches_params(pool)
    if params[:search][:name_contains]
      Pool.normalize_name_for_search(pool.name) == Pool.normalize_name_for_search(params[:search][:name_contains])
    else
      true
    end
  end
end
