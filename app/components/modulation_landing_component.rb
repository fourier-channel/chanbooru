# frozen_string_literal: true

# The landing page: a shuffled slideshow of what the site holds, the current
# featured creator, and the promoted ones.
#
# Written to be worth looking at with NOTHING in it. A new site has no promoted
# creators and no feature, and a landing page that renders empty boxes in that
# state is worse than one that renders nothing -- so every section here asks
# whether it has anything to say before it takes up space.
class ModulationLandingComponent < ApplicationComponent
  attr_reader :categories, :feature, :promoted, :preference, :viewer

  def initialize(categories:, feature: nil, promoted: [], preference: nil, viewer: nil)
    super
    @categories = categories.to_a
    @feature = feature
    @promoted = promoted.to_a
    @preference = preference.to_s
    @viewer = viewer
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

  def feature?
    feature.present?
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
      # The whole set travels to the client: every axis has to be renderable at
      # any position, including the ones not on screen, because that is what
      # "up from image X lands on image X" means.
      categories: categories,
      # How long a slide holds before the next one.
      advanceMs: 6_000,
      # How long the resume control takes to fill before it restarts the ride.
      resumeMs: 10_000,
      # No periodic re-fetch. The carousel cycling three categories is what keeps
      # a page left open from becoming a fixed poster, and a background swap
      # would either yank the slide out from under a reader or silently undo the
      # pause they asked for.
    }
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
    post = gallery.creator_gallery_posts.includes(post: :media_asset).lazy.filter_map { |cgp| cgp.post }.find { |p| p.visible?(viewer) }
    post&.preview_file_url
  rescue StandardError
    nil
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end
end
