# frozen_string_literal: true

# A run of post cards on a drawn page (an artist's posts, a wiki page's, the
# popular page): the gallery's card, from the gallery's own mixin and markup,
# in a grid of its own. It draws a PostStripSurface and decides nothing: which
# posts, their links, their data attributes and their thumbnails are the
# surface's, decided for the viewer in core.
#
# Not the gallery: no .modgal, no .modgal-grid -- the gallery window, the tag
# popup and the hype script boot on those, and :has(.modgal) hides the
# sidebar -- and no data-tag-categories, so the hover panel does not boot. A
# card is never is-off: there is no window here.
#
# With no posts it draws its heading and its empty_text when it has one, and
# its footer when it has one (a paginator past the end still offers the way
# back, as upstream's gallery does); with none of the three, nothing.
class ModulationPostStripComponent < ApplicationComponent
  # A footer under the grid, e.g. a paginator.
  renders_one :footer

  attr_reader :surface, :title, :href, :empty_text

  # @param surface [PostStripSurface] the posts and card data, decided for
  #   the viewer
  # @param title [String, nil] the strip's label; none draws no heading
  # @param href [String, nil] where the label links (the full search)
  # @param empty_text [String, nil] what the strip says when it draws no
  #   card (upstream's "No posts found."); none draws no line
  def initialize(surface:, title: nil, href: nil, empty_text: nil)
    super
    @surface = surface
    @title = title
    @href = href
    @empty_text = empty_text
  end

  def render?
    surface.posts.any? || empty_text.present? || footer?
  end
end
