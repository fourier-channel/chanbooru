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
    @featured_posts ||= gallery.creator_gallery_posts.includes(post: :media_asset).filter_map do |cgp|
      # hidden_from? too: a curated post can sit under a creator prefix the
      # list hides from this viewer, and visible? does not know about that.
      cgp.post if cgp.post&.visible?(viewer) && !cgp.post.hidden_from?(viewer)
    end
  end

  # THE GALLERY IS A LIST, bounded like every other (operator, 2026-10-18):
  # below full browsing the first User#listing_per_page_limit posts are drawn
  # in full, and the rest of the gallery is laid out as it would be, one card
  # a post, carrying nothing of the post -- no media URL, no tags, no id, no
  # link -- so a visitor sees how much there is and view-source holds empty
  # boxes. "The opposite of the sudden fade to transparency paywall."
  def shown_posts
    viewer.can_browse_freely? ? featured_posts : featured_posts.first(viewer.listing_per_page_limit)
  end

  # How many posts lie past the cut: drawn as empty cards, and counted
  # (counts are a non issue, operator 2026-10-17).
  def locked_count
    featured_posts.size - shown_posts.size
  end

  def messages
    gallery.creator_gallery_messages
  end

  # The creator's original characters: their standing claims (CharacterClaim),
  # one query. A member gets links to each one's posts and wiki page; a
  # signed-out visitor, who reaches only a promoted gallery, gets the names,
  # because both links lead to members-only pages. Never a name hidden from
  # the viewer (a quarantined name, TagQuarantine).
  def characters
    @characters ||= CharacterClaim.where(creator_gallery_id: gallery.id).standing.map(&:tag_name).reject { |name| TagQuarantine.hidden_name?(name, viewer) }.sort
  end

  def member? = MembersOnly.member?(viewer)

  def thumb(post)
    post.visible?(viewer) && !post.hidden_from?(viewer) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  def post_link(post)
    helpers.post_path(post)
  end

  # matrix.to deep link opens the viewer's Matrix client to message the creator.
  def matrix_url
    "https://matrix.to/#/#{gallery.contact}"
  end
end
