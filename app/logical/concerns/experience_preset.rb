# frozen_string_literal: true

# Chooses the *experience preset* -- the UI skin a page renders in.
#
# "Modulation" is the chanbooru interface and the default everywhere. The
# upstream Danbooru interface is retained as a hidden "historical" preset for
# side-by-side testing; nothing in the UI links to it, and it is reachable only
# by asking for it explicitly (?preset=historical).
#
# An explicit ?preset= is sticky for the session, so a tester can enter
# historical once and keep clicking without re-appending the parameter.
# ?preset=modulation leaves historical again, which is the only documented way
# back out besides dropping the session.
module ExperiencePreset
  extend ActiveSupport::Concern

  MODULATION = "modulation"
  HISTORICAL = "historical"
  PRESETS = [MODULATION, HISTORICAL].freeze
  DEFAULT = MODULATION
  SESSION_KEY = :experience_preset

  included do
    helper_method :experience_preset, :modulation?, :historical?
  end

  # @return [String] the preset this request renders in; always one of PRESETS.
  def experience_preset
    @experience_preset ||= resolve_experience_preset
  end

  def modulation?
    experience_preset == MODULATION
  end

  def historical?
    experience_preset == HISTORICAL
  end

  private

  def resolve_experience_preset
    requested = params[:preset].to_s.downcase.strip

    # An explicit, recognised preset wins and is remembered for the session.
    # An unrecognised one is not an error -- it just means "the default", and it
    # clears any stickiness so a typo cannot strand someone in historical.
    if requested.present?
      chosen = PRESETS.include?(requested) ? requested : DEFAULT
      remember_experience_preset(chosen)
      return chosen
    end

    stored = session[SESSION_KEY].to_s
    PRESETS.include?(stored) ? stored : DEFAULT
  end

  # Only historical needs remembering; modulation is the default, so storing it
  # would put a cookie on every anonymous visitor for no gain.
  def remember_experience_preset(preset)
    if preset == DEFAULT
      session.delete(SESSION_KEY) if session[SESSION_KEY].present?
    else
      session[SESSION_KEY] = preset
    end
  rescue StandardError
    # Sessions are skipped on publicly-cached responses; the preset still
    # applies to this request via the parameter, it just does not persist.
    nil
  end
end
