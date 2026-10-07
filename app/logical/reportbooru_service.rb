# frozen_string_literal: true

# An API client for the Reportbooru service. Reportbooru tracks post view
# counts, post search counts, and missed search counts.
#
# Fork: only the search rankings are read, for the popular-searches sidebar.
# The view and missed-search rankings fed /explore/posts/viewed and
# /explore/posts/missed_searches, removed 2026-10-07 (this booru runs no
# Reportbooru, so they rendered empty).
#
# @see https://github.com/r888888888/reportbooru
class ReportbooruService
  attr_reader :http, :reportbooru_server

  def initialize(http: Danbooru::Http.internal, reportbooru_server: Danbooru.config.reportbooru_server)
    @reportbooru_server = reportbooru_server
    @http = http.timeout(1)
  end

  # @return [Boolean] true if Reportbooru is configured
  def enabled?
    reportbooru_server.present?
  end

  # Get the list of the day's top searches.
  # @param date [Date] the date to check (YYYY-MM-DD)
  # @param expires_in [Integer] the length of time to cache the results
  # @return [Array<Array<(String, Float)>>] a map from searches to search counts
  def post_search_rankings(date, expires_in: 1.minute)
    request("#{reportbooru_server}/post_searches/rank?date=#{date}", expires_in)
  end

  def popular_searches(date, limit: 100, expires_in: 1.hour)
    ranking = post_search_rankings(date, expires_in: expires_in)
    ranking = post_search_rankings(date.yesterday, expires_in: expires_in) if ranking.blank?
    ranking.take(limit).map(&:first)
  end

  # Send a request to Reportbooru
  # @param url [String] the full Reportbooru URL
  # @param expires_in [Integer] the length of time to cache the results
  # @return [Object] the parsed JSON response
  def request(url, expires_in)
    return [] unless enabled?

    response = http.cache(expires_in).get(url)
    return [] if response.status != 200
    JSON.parse(response.to_s.force_encoding("utf-8"))
  end
end
