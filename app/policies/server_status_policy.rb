# frozen_string_literal: true

class ServerStatusPolicy < ApplicationPolicy
  # Upstream inherits ApplicationPolicy#show?, which is unconditionally true, so
  # /status and /status.json answer a signed-out visitor with the full version
  # manifest. This fork restricts it -- see
  # Danbooru.config.status_page_visibility_level for the reasoning and for why
  # the restriction is inert in the test environment.
  def show?
    user.can_see_server_status?
  end

  # Rate limits are stored in the database, so don't apply one when the database is down.
  def rate_limit_for_show(**_options)
    return {} unless record.postgres_up?

    { rate: 2.0 / 1.second, burst: 10 }
  end
end
