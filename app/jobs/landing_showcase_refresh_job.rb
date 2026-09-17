# frozen_string_literal: true

# Runs the searches behind a multi-tag carousel category, off the request.
#
# Spawned two ways, on purpose:
#   * By LandingShowcaseCache when a visitor's read finds the list missing or
#     older than STALE_AFTER. Self-healing -- it needs no scheduler to be
#     correct, only to be prompt.
#   * By DanbooruMaintenance.hourly, so the list stays warm on a quiet site
#     where nobody has loaded the front page for a while.
#
# Takes the category KEY rather than the record: a job argument is serialised
# and may sit in a queue while an admin edits the row, and re-reading it here
# means the job runs against the configuration as it is now rather than as it
# was when somebody loaded a page.
class LandingShowcaseRefreshJob < ApplicationJob
  # @param key [String, nil] one category, or nil for every visible one that
  #   needs more than a single search.
  def perform(key = nil)
    specs_for(key).each do |spec|
      stored = LandingShowcaseCache.refresh!(spec)
      DanbooruLogger.info(
        "landing showcase refreshed #{spec.key}: #{spec.queries.length} queries, #{stored} candidates",
        context: "landing_showcase_refresh", category: spec.key,
      )
    end
  end

  private

  def specs_for(key)
    rows = key ? LandingCategory.visible.where(key: key) : LandingCategory.visible
    # ONLY the ones that need it. A single-query category is one bounded search
    # in the request and is meant to stay live; refreshing it here would put a
    # fifteen-minute delay on the row whose entire purpose is to be current.
    rows.to_a.select { |spec| spec.queries.length > 1 }
  end
end
