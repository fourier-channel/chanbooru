# frozen_string_literal: true

# Persists Modulation view state (image size cap, tags panel expansion)
# server-side -- no generated page may use browser storage (repo rule 9).
# A signed-in viewer gets a sidecar row; an anonymous viewer gets the same
# hash in their Rails session, so the state survives navigation either way.
class ModulationSettingsController < ApplicationController
  respond_to :json

  # Every settable key, in one list -- building the changes hash by hand is
  # how session_bar_open got silently dropped on arrival (the model accepted
  # it; the controller never passed it).
  KEYS = (ModulationSetting::PANEL_KEYS + %w[reveal_banished]).freeze

  # Self-scoped by construction: the write reaches only the caller's own row
  # or session, so there is no foreign resource to authorize against.
  def update
    skip_authorization
    changes = KEYS.index_with { |k| params[k] }.compact
    settings = ModulationSetting.record!(CurrentUser.user, session, changes)
    render json: settings, status: :ok
  end
end
