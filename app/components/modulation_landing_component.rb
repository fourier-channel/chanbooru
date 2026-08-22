# frozen_string_literal: true

# The landing page: a shuffled slideshow of what the site holds, the current
# featured creator, and the promoted ones.
#
# Written to be worth looking at with NOTHING in it. A new site has no promoted
# creators and no feature, and a landing page that renders empty boxes in that
# state is worse than one that renders nothing -- so every section here asks
# whether it has anything to say before it takes up space.
class ModulationLandingComponent < ApplicationComponent
  attr_reader :slides, :feature, :promoted, :preference, :viewer

  def initialize(slides:, feature: nil, promoted: [], preference: nil, viewer: nil)
    super
    @slides = slides.to_a
    @feature = feature
    @promoted = promoted.to_a
    @preference = preference.to_s
    @viewer = viewer
  end

  def any_slides?
    slides.any?
  end

  def feature?
    feature.present?
  end

  def promoted?
    promoted.any?
  end

  # The showcase refreshes itself; these travel to the client as one blob rather
  # than as a dozen data attributes.
  def config
    {
      slidesUrl: routes.landing_slides_path(format: :json),
      # How long a slide holds before the next one.
      advanceMs: 6_000,
      # How long before the whole set is replaced with a fresh shuffle, so a
      # page left open does not become a fixed poster.
      refreshMs: 5 * 60 * 1_000,
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
