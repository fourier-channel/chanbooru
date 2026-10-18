# frozen_string_literal: true

# The Modulation gallery's grid: THE card renderer, for the page and for the
# chunks its window fetches (posts/index.html+window), so a card that arrives
# later is the same markup as one drawn with the page.
#
# On the page it carries the window (GALLERY_WINDOW.md section 2): the
# gallery draws WINDOW_CHUNK cards and shows the first WINDOW_SLOTS, the rest
# marked is-off; gallery_window.js keeps the box filled with the cards the
# blocklist lets render, fetching chunks of the same search from the cards'
# cursors (data-key). A chunk's cards all arrive is-off; the window places
# them. Everything the window needs is on the grid, from these constants:
# the box, the chunk sizes, how far one action may look before it asks
# (budget: raw posts and fetches), how many cards it keeps behind the box
# and how many in all.
class ModulationGalleryComponent::GridComponent < ApplicationComponent
  WINDOW_CONFIG = {
    slots: PostSets::Post::WINDOW_SLOTS,
    chunk: PostSets::Post::WINDOW_CHUNK,
    chunkMax: PostSets::Post::WINDOW_CHUNK_MAX,
    budgetRaw: 400,
    budgetFetches: 6,
    keepBehind: 60,
    hardCap: 500,
  }.freeze

  # The chunk format. A page whose script expects another refuses the chunk
  # and says to reload, rather than placing cards it may misread.
  WINDOW_VERSION = "1"

  attr_reader :gallery

  delegate :post_set, to: :gallery

  # @param gallery [ModulationGalleryComponent] the gallery whose posts and
  #   card data these are
  # @param chunk [Boolean] a fetched run: every card arrives off
  def initialize(gallery:, chunk: false)
    super
    @gallery = gallery
    @chunk = chunk
  end

  def chunk? = @chunk

  def off?(index)
    chunk? || index >= WINDOW_CONFIG[:slots]
  end

  # The grid's attributes: the hover panel's maps, and the window's state
  # when this viewer has one.
  def grid_data
    data = { "data-tag-categories" => gallery.page_tag_categories.to_json, "data-tag-counts" => gallery.page_tag_counts.to_json }
    # Below the browsing tier the gallery is one page: which empty state is
    # true when the blocklist hides all of it.
    data["data-one-page"] = "true" unless gallery.can_browse?
    return data unless post_set.windowing?

    data.merge!(
      "data-window" => WINDOW_CONFIG.to_json,
      "data-window-v" => WINDOW_VERSION,
      "data-window-kind" => post_set.window_kind,
      "data-window-tags" => post_set.tag_string.to_s.strip,
      "data-window-anchor" => anchor_cursor.to_s,
      "data-more-ahead" => post_set.window_more_ahead?.to_s,
    )
    # Whether the search goes on behind: the page's (its prev needs it
    # anyway) and a backward chunk's (free: the row past its limit). A
    # forward chunk would pay a second keyset query for an answer the window
    # never reads, so it has none.
    data["data-more-behind"] = post_set.window_more_behind?.to_s unless chunk? && !post_set.seek&.backward?
    data
  end

  # The place this run opens at: its first card's cursor when the page was
  # opened at a place, empty at the head of the search.
  def anchor_cursor
    seek = post_set.seek
    return nil if seek.nil? || (seek.id.nil? && seek.offset.to_i == 0)

    post_set.window_cursors[gallery.posts.first&.id]
  end
end
