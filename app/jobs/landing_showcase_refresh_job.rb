# frozen_string_literal: true

# Runs the searches behind a multi-tag carousel category, off the request.
#
# Spawned two ways, on purpose:
#   * By LandingShowcaseCache when a visitor's read finds the list missing or
#     older than STALE_AFTER. Self-healing -- it needs no scheduler to be
#     correct, only to be prompt.
#   * By the "landing-showcase" clockwork event every landing_refresh_every,
#     so the list stays warm on a quiet site where nobody has loaded the front
#     page for a while. (It was DanbooruMaintenance.hourly until 2026-09-19.)
#
# Takes the category KEY rather than the record: a job argument is serialised
# and may sit in a queue while an admin edits the row, and re-reading it here
# means the job runs against the configuration as it is now rather than as it
# was when somebody loaded a page.
class LandingShowcaseRefreshJob < ApplicationJob
  # @param key [String, nil] one category, or nil for every visible one that
  #   needs more than a single search.
  #
  # One row whose every search failed does not stop the others refreshing;
  # its failure is raised once they have run, so the job queue shows it.
  def perform(key = nil)
    failures = specs_for(key).filter_map do |spec|
      stored = LandingShowcaseCache.refresh!(spec)
      DanbooruLogger.info(
        "landing showcase refreshed #{spec.key}: #{spec.queries.length} queries, #{stored} candidates",
        context: "landing_showcase_refresh", category: spec.key,
      )
      nil
    rescue LandingShowcaseCache::Error => e
      e.message
    end
    raise LandingShowcaseCache::Error, failures.join("; ") if failures.any?
  end

  private

  def specs_for(key)
    # The rows the page shows (LandingShowcase#specs reads the same list).
    rows = LandingCategory.configured.select(&:enabled?)
    rows = rows.select { |spec| spec.key == key } if key
    # ONLY the ones that need it. A single-query category is one bounded search
    # in the request and is meant to stay live; refreshing it here would put a
    # fifteen-minute delay on the row whose entire purpose is to be current.
    rows.to_a.select { |spec| spec.queries.length > 1 }
  end
end
