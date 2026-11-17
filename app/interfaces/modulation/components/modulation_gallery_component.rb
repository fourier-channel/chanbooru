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
#
# It draws a GallerySurface (interfaces stage 1, step 4b): what the viewer is
# offered -- which tags, which thumbnails, the search box or the sign-in line,
# the excerpt, the pager -- is decided there, for the viewer it was handed.
class ModulationGalleryComponent < ApplicationComponent
  attr_reader :surface

  delegate :boards, :board_active?, :board_href, :searchable?, :tag_href, :active_sort, :initial_view,
           :posts, :query_string, :tag_groups, :unitag_list, :any_tags?, :excerpt, :excerpt_owner,
           :truncated?, :post_count, :windowing?, :window_kind, :next_href, :prev_href, :pager_note,
           to: :surface

  def initialize(surface:)
    super
    @surface = surface
  end

  # A summary, not the article: the wiki page is one click away and a long entry
  # would push the posts off the screen the viewer came for.
  def excerpt_summary
    body = excerpt&.dig(:body).to_s.strip
    return nil if body.blank?

    # DText bodies are stored with CRLF, so a bare /\n{2,}/ never splits and the
    # whole article comes through as one "first paragraph".
    first = body.split(/(?:\r?\n){2,}/).first.to_s.squish
    (first.length > 320) ? "#{first[0, 317]}..." : first
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  # The pill's classes: provenance paints it, category only for the
  # identifying kinds (the post page's rule; the stylesheet's compound
  # category selector is what makes artist/character/copyright win).
  def pill_classes(tag)
    "mod-pill mod-pill--#{surface.page_tag_provenance.dig(tag.name, 0) || "unsourced"} mod-pill--cat mod-pill--cat-#{surface.category_key(tag)}"
  end

  # The dot's lamp class. No row: no model, a person's white lamp.
  def dot_classes(tag)
    "mod-pill-dot mod-pill-dot--#{surface.page_tag_provenance.dig(tag.name, 1) || :manual}"
  end
end
