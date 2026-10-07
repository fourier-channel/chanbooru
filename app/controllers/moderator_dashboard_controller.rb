# frozen_string_literal: true

class ModeratorDashboardController < ApplicationController
  def show
    # Fork: its mod actions and comments name posts, and upstream shows it to
    # anyone (an empty policy). Members only (MembersOnly).
    MembersOnly.post_listing!(CurrentUser.user)
    @dashboard = authorize ModeratorDashboard.new(**search_params.to_h.symbolize_keys)
  end
end
