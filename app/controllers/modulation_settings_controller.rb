# frozen_string_literal: true

# Persists Modulation view state (image size cap, tags panel expansion)
# server-side -- no generated page may use browser storage (repo rule 9).
# A signed-in viewer gets a sidecar row; an anonymous viewer gets the same
# hash in their Rails session, so the state survives navigation either way.
class ModulationSettingsController < ApplicationController
  respond_to :json

  # Self-scoped by construction: the write reaches only the caller's own row
  # or session, so there is no foreign resource to authorize against.
  def update
    skip_authorization
    changes = { "image_cap" => params[:image_cap], "tags_expanded" => params[:tags_expanded], "reveal_banished" => params[:reveal_banished] }.compact
    settings = ModulationSetting.record!(CurrentUser.user, session, changes)
    render json: settings, status: :ok
  end
end
