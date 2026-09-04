# frozen_string_literal: true

# Per-user view state for the Modulation interface (sidecar table, one row per
# user -- see the migration for why it is not a users column). View state
# persists server-side because no generated page may use browser storage
# (repo rule 9); a logged-out viewer's copy lives in their Rails session under
# SESSION_KEY, shaped exactly like #as_json.
class ModulationSetting < ApplicationRecord
  belongs_to :user

  # fit: fill the page to the point the collapsed Tags panel is still visible
  #      (the default; the client measures the actual chrome).
  # screen: fill the viewport height, tags below the fold.
  # none: the image's natural size.
  IMAGE_CAPS = %w[fit screen none].freeze

  SESSION_KEY = :modulation_settings

  validates :image_cap, inclusion: { in: IMAGE_CAPS }

  def self.defaults
    { "image_cap" => "fit", "tags_expanded" => false }
  end

  # The settings hash for a viewer, merged over defaults. `session` supplies
  # the anonymous copy; a signed-in user's row wins over any session leftovers.
  def self.for_viewer(user, session = nil)
    if user.present? && !user.is_anonymous?
      row = find_by(user_id: user.id)
      defaults.merge(row ? row.slice("image_cap", "tags_expanded") : {})
    else
      defaults.merge((session && session[SESSION_KEY]).presence || {})
    end
  end

  # Persist a change for a viewer. Unknown keys are dropped, values validated;
  # returns the resulting settings hash.
  def self.record!(user, session, changes)
    clean = {}
    cap = changes["image_cap"].presence
    clean["image_cap"] = cap if IMAGE_CAPS.include?(cap)
    clean["tags_expanded"] = changes["tags_expanded"].to_s.truthy? unless changes["tags_expanded"].nil?
    # Admin-only, row-only: revealing the banished vocabulary is a deliberate
    # act (see TagBanishment), and it means nothing in an anonymous session.
    if !changes["reveal_banished"].nil? && user.respond_to?(:is_admin?) && user.is_admin?
      clean["reveal_banished"] = changes["reveal_banished"].to_s.truthy?
    end
    return for_viewer(user, session) if clean.empty?

    if user.present? && !user.is_anonymous?
      row = find_or_initialize_by(user_id: user.id)
      row.update!(clean)
    elsif session
      session[SESSION_KEY] = defaults.merge((session[SESSION_KEY] || {}).merge(clean))
    end
    for_viewer(user, session)
  end
end
