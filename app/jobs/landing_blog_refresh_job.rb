# frozen_string_literal: true

# Reads the blog's index for the landing carousel's Blog row, off the request.
#
# Spawned two ways, like LandingShowcaseRefreshJob and beside it:
#   * By LandingBlogCache when a visit finds the cache cold or stale.
#   * By the "landing-showcase" clockwork event, on the same interval, so a
#     quiet site does not go cold.
#
# A failed read RAISES, after LandingBlogCache has recorded it for the console:
# the job queue is where a failure shows, and it is a separate job so a blog
# outage cannot stop the creator rows refreshing.
class LandingBlogRefreshJob < ApplicationJob
  def perform
    count = LandingBlogCache.refresh!
    DanbooruLogger.info("landing blog refreshed: #{count} posts from #{LandingBlogCache.index_url}")
  end
end
