# frozen_string_literal: true

module Explore
  class PostsController < ApplicationController
    respond_to :html, :xml, :json

    # Members only, every format (operator ruling 2026-10-07): a signed-out
    # visitor could ask for any page of any day's posts at any `limit=`, so
    # walking ?date= backwards listed the whole booru. See MembersOnly.
    #
    # viewed, searches and missed_searches were removed the same day: they
    # read Reportbooru, which this booru does not run, so they rendered empty
    # (operator: "If we're not using it and it won't break anything then
    # close it off altogether").
    before_action { MembersOnly.post_listing!(CurrentUser.user) }

    def popular
      @date, @scale, @min_date, @max_date = parse_date(params)

      limit = params.fetch(:limit, CurrentUser.user.per_page)
      @posts = popular_posts(@min_date, @max_date).paginate(params[:page], limit: limit, search_count: false)
      authorize @posts, policy_class: ExplorePostPolicy

      respond_with(@posts)
    end

    private

    def parse_date(params)
      date = params[:date].present? ? Date.parse(params[:date]) : Date.today
      scale = params[:scale].in?(["day", "week", "month"]) ? params[:scale] : "day"
      min_date = date.send("beginning_of_#{scale}")
      max_date = date.send("next_#{scale}").send("beginning_of_#{scale}")

      [date, scale, min_date, max_date]
    end

    def popular_posts(min_date, max_date)
      Post.where(created_at: min_date..max_date).includes(:media_asset).user_tag_match("order:score")
    end
  end
end
