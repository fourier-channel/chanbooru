# frozen_string_literal: true

module Moderator
  module Post
    class PostsController < ApplicationController
      respond_to :html, :json, :xml, :js

      # Fork: every action finds its post with Post.find_writable! -- the
      # moderation tier acts on deleted and jailed posts, never on one its
      # creator hid (CREATOR_VISIBILITY Q2: moderators see nothing a creator
      # hid; 2026-10-08), and ban and unban answer with the whole post.

      def confirm_move_favorites
        @post = authorize ::Post.find_writable!(params[:id])
      end

      def move_favorites
        @post = authorize ::Post.find_writable!(params[:id])
        if params[:commit] == "Submit"
          @post.give_favorites_to_parent
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
