# frozen_string_literal: true

# A job that runs hourly to clear IP addresses, user agents and session ids
# older than IpDataPruner::MAX_AGE. Spawned by {DanbooruMaintenance}.
class PruneIpDataJob < ApplicationJob
  def perform
    IpDataPruner.new.prune!
  end
end
