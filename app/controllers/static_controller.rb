# frozen_string_literal: true

class StaticController < ApplicationController
  respond_to :html, :json, :xml
  skip_forgery_protection only: :not_found, if: -> { request.format.js? }

  after_action :skip_authorization

  def privacy_policy
  end

  def terms_of_service
  end

  # Fork: no pool picture. Upstream drew a random post from
  # page_not_found_pool_id here with no check of who may see it; the "Oh No!"
  # page draws its own, by the hero band's rule (ErrorPagePicture).
  def not_found
    render_error_page(404, nil, template: "static/not_found", message: "Page not found")
  end

  def error
  end

  def dtext_help
    redirect_to wiki_page_path("help:dtext") unless request.format.js?
  end

  def colors
  end

  def components
  end

  def opensearch
  end

  def site_map
  end

  def sitemap_index
    @sitemap = params[:sitemap]
    @limit = params.fetch(:limit, 10_000).to_i

    case @sitemap
    when "artists"
      @relation = Artist.undeleted
      @search = { is_deleted: "false" }
    when "forum_topics"
      @relation = ForumTopic.undeleted
      @search = { is_deleted: "false" }
    when "pools"
      @relation = Pool.undeleted
      @search = { is_deleted: "false" }
    when "posts"
      @relation = Post.order(id: :asc)
      @search = {}
    when "tags"
      @relation = Tag.nonempty
      @search = {}
    when "users"
      @relation = User.all
      @search = {}
    when "wiki_pages"
      @relation = WikiPage.undeleted
      @search = { is_deleted: "false" }
    else
      raise NotImplementedError
    end
  end
end
