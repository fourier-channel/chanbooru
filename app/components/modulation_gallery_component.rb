# frozen_string_literal: true

# "Modulation" gallery -- the post index in the Modulation theme. Same visual
# language as the post view (dark, token-driven, colour-coded tag pills with a
# unitag/grouped toggle); here the tags are the search's facet tags and the
# grouping dimension is tag CATEGORY rather than provenance.
#
# Tag search is the primary control ("sort by via tag search"). Thumbnails link
# into the Modulation post view carrying the current search as navigation
# context, so the post view's "search" preset picks up exactly where the gallery
# left off.
class ModulationGalleryComponent < ApplicationComponent
  attr_reader :post_set, :viewer

  # Display order for the category buckets.
  CATEGORY_ORDER = %w[artist copyright character general meta].freeze

  def initialize(post_set:, viewer:)
    super
    @post_set = post_set
    @viewer = viewer
  end

  def posts
    post_set.posts
  end

  def query_string
    post_set.tag_string.to_s.strip
  end

  # The post view link, carrying the search so its nav follows this exact search.
  def post_link(post)
    routes.post_path(post, preset: "modulation", q: query_string.presence)
  end

  # Facet tags grouped by category, in display order: [[key, [tags]], ...].
  def tag_groups
    grouped = post_set.sidebar_tags.group_by { |t| category_key(t) }
    CATEGORY_ORDER.filter_map { |k| [k, grouped[k]] if grouped[k].present? }
  end

  # Flat unitag list: [[tag, category_key], ...] in the same category order.
  def unitag_list
    tag_groups.flat_map { |key, tags| tags.map { |t| [t, key] } }
  end

  def any_tags?
    post_set.sidebar_tags.any?
  end

  # Blacklist rules are matched client-side against these attributes, so every
  # card has to carry them or the viewer's blacklist silently does not apply --
  # which is what happened for as long as this gallery rendered bare <a> cards
  # and the blacklist's selector list knew nothing about them.
  #
  # data-tags comes from FourierTagSource.blacklist_tags_for, NOT post.tag_string:
  # tag_string still holds the private creator tags, and this is the default view
  # of the site.
  def card_data(post)
    {
      "data-id" => post.id,
      "data-tags" => blacklist_tags[post].to_a.join(" "),
      "data-rating" => post.rating,
      "data-flags" => post.status_flags,
      "data-score" => post.score,
      "data-uploader-id" => post.uploader_id,
    }
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for(posts, viewer)
  end

  def thumb_for(post)
    post.visible?(viewer) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  def current_page
    [post_set.current_page.to_i, 1].max
  end

  def more_pages?
    posts.size >= post_set.per_page
  end

  def page_url(page)
    routes.posts_path(preset: "modulation", tags: query_string.presence, page: (page if page > 1))
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  def category_key(tag)
    return "artist" if tag.artist?
    return "copyright" if tag.copyright?
    return "character" if tag.character?
    return "meta" if tag.meta?

    "general"
  end
end
