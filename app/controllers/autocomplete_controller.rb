# frozen_string_literal: true

class AutocompleteController < ApplicationController
  respond_to :html, :xml, :json

  def index
    @query = params.dig(:search, :query)
    @type = params.dig(:search, :type)
    @limit = params.fetch(:limit, 10).to_i
    @autocomplete = authorize AutocompleteService.new(@query, @type, current_user: CurrentUser.user, limit: @limit)

    @results = @autocomplete.autocomplete_results
    # Fork: cached as upstream caches it only when the caller names the
    # quarantine generation it was rendered with (`tv`, the booru's own JS
    # sends it): a flagged or banished name flip is then a new key at once.
    # Any other caller -- the opensearch suggestion URL, an old bookmark,
    # another client -- gets a minute, privately, with no stale serving.
    if params[:tv].to_s == TagQuarantine.names_generation
      @expires_in = @autocomplete.cache_duration
      @stale_while_revalidate = @autocomplete.stale_while_revalidate_duration
      @public = @autocomplete.cache_publicly?
    else
      @expires_in = 1.minute
      @stale_while_revalidate = nil
      @public = false
    end

    unless response.cache_control.present?
      @stale_while_revalidate ? expires_in(@expires_in, stale_while_revalidate: @stale_while_revalidate, public: @public) : expires_in(@expires_in, public: @public)
    end
    respond_with(@results, layout: false)
  end
end
