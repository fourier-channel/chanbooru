# frozen_string_literal: true

# Per-user view state for the Modulation interface (sidecar table, one row per
# user -- see the migration for why it is not a users column). View state
# persists server-side because no generated page may use browser storage
# (repo rule 9); a logged-out viewer's copy lives in their Rails session under
# SESSION_KEY, shaped exactly like the defaults hash.
class ModulationSetting < ApplicationRecord
  belongs_to :user

  # fit: fill the page to the point the collapsed Tags panel is still visible
  #      (the default; the client measures the actual chrome).
  # screen: fill the viewport height, tags below the fold.
  # none: the image's natural size.
  IMAGE_CAPS = %w[fit screen none].freeze

  # The sorts the gallery panel may remember: the orders PostNeighbors can
  # keyset over, plus random. A remembered sort is fed back into an order:
  # metatag, so an arbitrary string here would be a query injection point --
  # the whitelist is the gate.
  GALLERY_SORTS = %w[
    id id_asc id_desc score score_asc favcount favcount_asc
    created_at created_at_asc created_at_desc change change_asc
    filesize filesize_asc mpixels mpixels_asc tagcount tagcount_asc random
  ].freeze

  GALLERY_VIEWS = %w[unitag grouped].freeze

  # The keys a viewer's settings hash carries; also what for_viewer reads off
  # a row, so a new column joins this list or it silently never persists.
  PANEL_KEYS = %w[image_cap tags_expanded gallery_sort gallery_view gallery_show_deleted session_bar_open session_autorefresh].freeze

  SESSION_KEY = :modulation_settings

  validates :image_cap, inclusion: { in: IMAGE_CAPS }
  validates :gallery_view, inclusion: { in: GALLERY_VIEWS }
  validates :gallery_sort, inclusion: { in: GALLERY_SORTS }, allow_nil: true

  def self.defaults
    {
      "image_cap" => "fit",
      "tags_expanded" => false,
      "gallery_sort" => nil,
      "gallery_view" => "unitag",
      "gallery_show_deleted" => false,
      "session_bar_open" => false,
      "session_autorefresh" => true,
    }
  end

  # The settings hash for a viewer, merged over defaults. `session` supplies
  # the anonymous copy; a signed-in user's row wins over any session leftovers.
  def self.for_viewer(user, session = nil)
    if user.present? && !user.is_anonymous?
      row = find_by(user_id: user.id)
      defaults.merge(row ? row.slice(*PANEL_KEYS) : {})
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
    # gallery_sort: "" clears the memory back to "no opinion" -- that is the
    # user's reset, and it must be expressible or the memory is a trap.
    unless changes["gallery_sort"].nil?
      sort = changes["gallery_sort"].to_s
      clean["gallery_sort"] = nil if sort.empty?
      clean["gallery_sort"] = sort if GALLERY_SORTS.include?(sort)
    end
    clean["gallery_view"] = changes["gallery_view"] if GALLERY_VIEWS.include?(changes["gallery_view"])
    clean["gallery_show_deleted"] = changes["gallery_show_deleted"].to_s.truthy? unless changes["gallery_show_deleted"].nil?
    clean["session_bar_open"] = changes["session_bar_open"].to_s.truthy? unless changes["session_bar_open"].nil?
    clean["session_autorefresh"] = changes["session_autorefresh"].to_s.truthy? unless changes["session_autorefresh"].nil?
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
