# frozen_string_literal: true

class PoolElementsController < ApplicationController
  respond_to :html, :xml, :json, :js

  def create
    @pool = Pool.find_by_name(params[:pool_name]) || Pool.find_by_id(params[:pool_id])
    raise ActiveRecord::RecordNotFound if @pool.nil?
    authorize(@pool, :update?)

    # A post hidden from the editor is "not found", as a missing one is:
    # 200 for a hidden post and 404 for a missing one told them apart.
    @post = Post.find_visible!(params[:post_id])
    @pool.add!(@post)
    respond_with(@pool)
  end
end
