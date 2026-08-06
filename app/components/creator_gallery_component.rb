# frozen_string_literal: true

# The public Creator Gallery page, in the Modulation theme. Renders the creator's
# curated posts in one of several selectable layout styles, their blog-style
# messages, and a "message on Matrix" link. Read-only; the edit affordances only
# appear when `can_edit` (owner or admin, decided by the controller/view).
class CreatorGalleryComponent < ApplicationComponent
  attr_reader :gallery, :viewer, :can_edit

  def initialize(gallery:, viewer:, can_edit: false)
    super
    @gallery = gallery
    @viewer = viewer
    @can_edit = can_edit
  end

  def style
    gallery.style.presence_in(CreatorGallery::STYLES) || "grid"
  end

  # Curated posts, in the creator's order, filtered to what the viewer may see.
  def featured_posts
    gallery.creator_gallery_posts.includes(post: :media_asset).filter_map do |cgp|
      cgp.post if cgp.post&.visible?(viewer)
    end
  end

  def messages
    gallery.creator_gallery_messages
  end

  def thumb(post)
    post.visible?(viewer) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  def post_link(post)
    helpers.post_path(post, preset: "modulation")
  end

  # matrix.to deep link opens the viewer's Matrix client to message the creator.
  def matrix_url
    "https://matrix.to/#/#{gallery.contact}"
  end
end
