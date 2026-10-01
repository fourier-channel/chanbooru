# frozen_string_literal: true

class CountsController < ApplicationController
  respond_to :html, :xml, :json

  def posts
    estimate_count = params.fetch(:estimate_count, "true").truthy?
    skip_cache = params.fetch(:skip_cache, "false").truthy?
    # Fork: with the viewer's implicit metatags -- the gated tags, deleted and
    # jailed posts they may not see -- as the post index counts. Without them
    # this answered `id:N` with 1 for a post whose page 404s, and counted
    # troll_jail and status:deleted for anyone (leak audit 2026-10-01).
    @count = PostQuery.normalize(params[:tags], current_user: CurrentUser.user, tag_limit: CurrentUser.user.tag_query_limit).with_implicit_metatags.fast_count(timeout: CurrentUser.statement_timeout, estimate_count: estimate_count, skip_cache: skip_cache)
    skip_authorization

    if request.format.xml?
      respond_with({ posts: @count }, root: "counts")
    else
      respond_with({ counts: { posts: @count }})
    end
  end
end
