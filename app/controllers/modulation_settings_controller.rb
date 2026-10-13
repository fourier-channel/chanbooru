# frozen_string_literal: true

# Persists Modulation view state (image size cap, tags panel expansion)
# server-side, and takes the header blocklist's edits (Blocklist).
# A signed-in viewer gets a sidecar row; an anonymous viewer gets the same
# hash in their Rails session, so the state survives navigation either way.
class ModulationSettingsController < ApplicationController
  respond_to :json

  # Every settable key, in one list -- building the changes hash by hand is
  # how session_bar_open got silently dropped on arrival (the model accepted
  # it; the controller never passed it).
  KEYS = ModulationSetting::PANEL_KEYS

  # Self-scoped by construction: the write reaches only the caller's own row
  # or session, so there is no foreign resource to authorize against.
  #
  # A `blocklist` parameter is an edit to the viewer's blocklist instead (the
  # header's pills; see Blocklist for the shape). A signed-in viewer's list
  # is the account's; a signed-out viewer's arrives as `list` from their
  # browser and is only normalised and checked here, never stored.
  def update
    skip_authorization
    return update_blocklist if params[:blocklist].present?

    changes = KEYS.index_with { |k| params[k] }.compact
    settings = ModulationSetting.record!(CurrentUser.user, session, changes)
    render json: settings, status: 200
  end

  private

  def update_blocklist
    edit = params.require(:blocklist)
    unless edit.is_a?(ActionController::Parameters)
      raise Blocklist::Refused, "A blocklist edit is an object: {\"blocklist\": {\"op\": \"add\", \"rule\": \"tag\"}}."
    end
    blocks = Blocklist.apply!(
      CurrentUser.user,
      op: edit[:op].to_s, rule: edit[:rule],
      blocks: edit[:blocks], list: edit[:list],
    )
    render json: { blocklist: blocks }, status: 200
  rescue Blocklist::Refused => e
    render json: { error: e.message }, status: 422
  end
end
