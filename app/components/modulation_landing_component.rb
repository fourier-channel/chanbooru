# frozen_string_literal: true

# The landing page: a shuffled slideshow of what the site holds, and the
# promoted creators beneath it.
#
# CREATOR OF THE MONTH HAS LEFT THIS COMPONENT, 2026-09-17, by operator ruling.
# It was a single gallery in its own section; the idea is now the plural
# "Featured Creators" row of the carousel, configured by artist tags on the
# landing console. The IDEA MOVED, it was not retired -- and CreatorGallery
# .featured_at is parked rather than dropped, for pinning a gallery to that row
# later. See the note on that column.
#
# Written to be worth looking at with NOTHING in it. A new site has no promoted
# creators, and a landing page that renders empty boxes in that state is worse
# than one that renders nothing -- so every section here asks whether it has
# anything to say before it takes up space.
class ModulationLandingComponent < ApplicationComponent
  attr_reader :categories, :promoted, :preference, :viewer

  # `settings` is the viewer's Modulation view state (ModulationSetting.for_viewer);
  # the landing page reads one key of it, hero_band, and renders the band
  # already maximised so a remembered choice does not flash into place.
  def initialize(categories:, promoted: [], preference: nil, viewer: nil, settings: nil)
    super
    @categories = categories.to_a
    @promoted = promoted.to_a
    @preference = preference.to_s
    @viewer = viewer
    @settings = settings || ModulationSetting.defaults
  end

  def hero_band?
    @settings["hero_band"].to_s.truthy?
  end

  def any_slides?
    categories.any?
  end

  # Every slide of every category, flattened. Rendered hidden so the blacklist
  # sees the whole set once at load: the carousel builds its visible cells from
  # the payload, but the blacklist matches on elements, and an element it never
  # saw is an element it never filtered.
  def all_slides
    categories.flat_map { |category| category[:slides].map { |slide| slide.merge(category: category[:key]) } }
  end

  def promoted?
    promoted.any?
  end

  # Viewer-scoped, like everything else here: the numbers describe the archive
  # as it exists for whoever is looking.
  def pulse
    @pulse ||= ArchivePulse.new(viewer: viewer)
  end

  # The showcase refreshes itself; these travel to the client as one blob rather
  # than as a dozen data attributes.
  def config
    {
      slidesUrl: routes.landing_slides_path(format: :json),
      # How often the page pulls a fresh set, FROM THE SAME CONSTANT the
      # scheduler and the staleness check read. A row on "random" is redrawn
      # server-side on that cadence; asking more often than that gets the same
      # answer, and asking less often means a draw nobody ever sees.
      refreshMs: LandingShowcaseCache::REFRESH_EVERY.to_i * 1_000,
      # The whole set travels to the client: every axis has to be renderable at
      # any position, including the ones not on screen, because that is what
      # "up from image X lands on image X" means.
      categories: categories,
      # How long a slide holds before the next one, FROM THE SETTING.
      #
      # This was the literal 6_000 while a landing_settings.advance_ms column
      # sat in the schema that nothing read -- the migration landed and the
      # surface never did, which is the same shape of gap the operator has
      # already had to point out once on this feature. A setting nothing reads
      # is worse than no setting: it is a control that looks like it works.
      advanceMs: landing_setting.advance_ms,
      # How long the resume control takes to fill before it restarts the ride.
      resumeMs: 10_000,
      # The band runs edge to edge, remembered (ModulationSetting.hero_band).
      heroBand: hero_band?,
      # No periodic re-fetch. The carousel cycling three categories is what keeps
      # a page left open from becoming a fixed poster, and a background swap
      # would either yank the slide out from under a reader or silently undo the
      # pause they asked for.
    }
  end

  # One row, read once per render. Memoized because #config is not the only
  # thing that may want it, and `first || new` is a query either way.
  def landing_setting
    @landing_setting ||= LandingSetting.current
  end

  def gallery_path
    routes.posts_path
  end

  def gallery_preferred?
    preference == LandingController::GALLERY
  end

  def gallery_link(gallery)
    routes.creator_gallery_path(gallery)
  end

  def gallery_title(gallery)
    gallery.title.presence || gallery.slug
  end

  # A creator's own curated pick, so the promoted row shows their work rather
  # than a placeholder. Nil when they have not curated anything the viewer may
  # see -- the row copes.
  def gallery_thumb(gallery)
    post = gallery.creator_gallery_posts.includes(post: :media_asset).lazy.filter_map(&:post).find { |p| p.visible?(viewer) }
    post&.preview_file_url
  rescue StandardError
    nil
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end
end
