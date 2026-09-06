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
end
