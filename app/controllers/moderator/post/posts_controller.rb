# frozen_string_literal: true

module Moderator
  module Post
    class PostsController < ApplicationController
      respond_to :html, :json, :xml, :js

      # Fork: every action finds its post with Post.find_writable! -- a post
      # hidden from the moderator is not found (R1, operator 2026-11-20: a
      # write is refused like the read), and ban and unban answer with the
      # whole post.

      def confirm_move_favorites
        @post = authorize ::Post.find_writable!(params[:id])
      end

      def move_favorites
        @post = authorize ::Post.find_writable!(params[:id])
        if params[:commit] == "Submit"
          @post.give_favorites_to_parent(CurrentUser.user)
        end
        redirect_to(post_path(@post))
      end

      def expunge
        @post = authorize ::Post.find_writable!(params[:id])
        @post.expunge!(CurrentUser.user)
      end

      def ban
        @post = authorize ::Post.find_writable!(params[:id])
        @post.ban!(CurrentUser.user)

        respond_with(@post, notice: "Post was banned")
      end

      def unban
        @post = authorize ::Post.find_writable!(params[:id])
        @post.unban!(CurrentUser.user)

        respond_with(@post, notice: "Post was unbanned")
      end
    end
  end
end
