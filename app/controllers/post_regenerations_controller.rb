# frozen_string_literal: true

class PostRegenerationsController < ApplicationController
  respond_to :xml, :json, :html

  def create
    # Not a post hidden from the moderator past deletion (Post#writable_by?):
    # this answers with the whole post (Q2, 2026-10-08).
    @post = authorize Post.find_writable!(params[:post_id]), :regenerate?
    @post.regenerate_later!(params[:category], CurrentUser.user)

    respond_with(@post, notice: "Post regeneration scheduled, press Ctrl+F5 in a few seconds to refresh the image")
  end
end
