# frozen_string_literal: true

# What the post index offers a viewer: the gallery's decisions, made once in
# core for every interface (interfaces stage 1, step 4b). It takes the viewer,
# the request and the session it is handed and reads no CurrentUser. The
# Modulation gallery and its grid (the page, and the chunks the gallery window
# fetches) draw what it returns and decide nothing themselves; an interface
# that drew the index without it would have to rebuild every check below, and
# one it missed would leak.
#
# The search's facet tags and the page's card tags go through TagBanishment;
# card tag marks and pill provenance are public rows only; card data carries
# the viewer's own blacklist projection; a thumbnail is drawn only for a post
# the viewer may see; the search box and tag links are offered only where
# MembersOnly lets them work; the excerpt withholds a banned artist; the
# browse check and the 21st-row probe hold a viewer below the browsing tier
# to their one page.
class GallerySurface
  include PostCards

  attr_reader :post_set, :viewer, :request

  # Display order for the category buckets.
  CATEGORY_ORDER = %w[artist copyright character general meta].freeze

  # ---- Board filter ---------------------------------------------------
  #
  # A post's provenance lives in its SOURCE, not in any tag. 4chan posts carry
  # `https://boards.4chan.org/<board>/thread/...` and Matrix posts carry
  # `mxc://41chan.net/<id>`, so the filter is a `source:` metatag with a
  # trailing wildcard. `source` is a real metatag in PostQueryBuilder, and the
  # wildcard form was run against live rows before this was written rather than
  # assumed -- it returns the right posts for all four.
  #
  # Four entries because four sources have content: b, d and trash are the
  # boards the sampler actually walks, and matrix is everything posted in the
  # community rooms. A fifth board is one line here.
  BOARDS = [
    { key: "b",      label: "/b/",     source: "source:https://boards.4chan.org/b/*" },
    { key: "d",      label: "/d/",     source: "source:https://boards.4chan.org/d/*" },
    { key: "trash",  label: "/trash/", source: "source:https://boards.4chan.org/trash/*" },
    { key: "matrix", label: "matrix",  source: "source:mxc://*" },
  ].freeze

  # @param post_set [PostSets::Post] the search, built for this viewer
  # @param viewer [User] whom every decision is made for
  # @param request [ActionDispatch::Request] whether the viewer is signed out
  #   (MembersOnly reads the request's identity)
  # @param session [Hash] where a signed-out viewer's settings live; read
  #   only when the page draws them, never for a window chunk
  def initialize(post_set:, viewer:, request:, session:)
    @post_set = post_set
    @viewer = viewer
    @request = request
    @session = session
  end

  def boards
    BOARDS
  end

  # The search as WHOLE terms. Whole terms matter: someone searching the
  # ordinary tag `matrix` must not have the matrix board light up as though
  # they had filtered by it, and a substring test would say exactly that.
  def query_terms
    @query_terms ||= query_string.split(/\s+/).reject(&:blank?)
  end

  def active_board
    return @active_board if defined?(@active_board)
    lowered = query_terms.map(&:downcase)
    @active_board = BOARDS.find { |b| lowered.include?(b[:source]) }
  end

  def board_active?(board)
    active_board.present? && active_board[:key] == board[:key]
  end

  # Each segment is a TOGGLE: clicking the board already in force clears it.
  # That is how a four-part pill reaches "everything" without a fifth segment,
  # and it means the control can always be put back to its resting state --
  # a filter you cannot turn off is a trap, not a filter.
  #
  # Every other term survives, `order:` included, so the filter composes with
  # the search rather than replacing it.
  def board_href(board)
    rest = query_terms.reject { |t| BOARDS.any? { |b| b[:source] == t.downcase } }
    rest << board[:source] unless board_active?(board)
    routes.posts_path(tags: rest.join(" ").presence)
  end

  # The search box, sort and board filter, offered only where they work. A
  # signed-out viewer may list the newest posts and a featured creator's tag
  # and nothing else (MembersOnly.anonymous_post_listing), and autocomplete is
  # no door open to them, so every keystroke and click 404'd (2026-10-13: 123
  # autocomplete 404s in a day). The rule stays; the controls do not show.
  def searchable?
    !(MembersOnly.default_deny? && MembersOnly.signed_out?(viewer, request))
  end

  # A tag pill's link, or nil for a plain label. A signed-out viewer may open
  # a tag search only for a featured creator's tag (MembersOnly), so every
  # other pill is drawn for them as a label rather than a link that 404s.
  def tag_href(tag)
    return routes.posts_path(tags: tag.name) if searchable?

    routes.posts_path(tags: tag.name) if (@featured_tags ||= MembersOnly.anonymous_featured_tags).include?(tag.name)
  end

  # The viewer's Modulation view state (ModulationSetting.for_viewer); the
  # panel draws its remembered sort, view and deleted toggle from it. Read
  # when first asked: the window chunk draws none of it.
  def settings
    @settings ||= ModulationSetting.for_viewer(viewer, @session)
  end

  # The sort the panel is set to: the query's own order (the panel memory has
  # already been woven in by the controller), falling back to the remembered
  # one so the select never shows blank while a memory is in force.
  def active_sort
    @active_sort ||= post_set.post_query.find_metatag(:order).presence&.downcase || settings["gallery_sort"]
  end

  def initial_view
    ModulationSetting::GALLERY_VIEWS.include?(settings["gallery_view"]) ? settings["gallery_view"] : "unitag"
  end

  # The posts this gallery will actually draw.
  #
  # Deleted posts are dropped unless the viewer has asked for them, which is
  # upstream's rule -- PostPreviewComponent#render? refuses to draw a deleted
  # post unless show_deleted -- and it was lost when this gallery replaced that
  # component. Worth naming, because the shape recurs: a fork that reimplements
  # an upstream view inherits its LAYOUT and silently drops its GUARDS. The
  # blacklist went the same way in this same component.
  #
  # Dropped in the query now (PostSets::Post#window_query), not here: the
  # gallery window pages by cursors minted from the cards it drew, and a
  # chunk of deleted posts dropped at render would draw nothing and name no
  # place past them. A banned post below Approver and a taken-down post below
  # Moderator are dropped there too (Post#banblocked?), for the same reason
  # and one more: the prev cursor is minted from the rows behind, so a row
  # the viewer may not list would name its id in a data-key or an anchor.
  #
  # And every post that does not exist for this viewer in a list
  # (PostPreviewComponent.listed?) is dropped HERE as well, on the page and
  # in every window chunk, whatever the query let through: the gated face is
  # for a post the viewer may list but not see (safe mode), never for one
  # that is not there for them -- a level-gated post, a banished one --
  # whose card would name its id (2026-11-18: post 50007 was drawn gated to
  # members while upstream omits it). A drawn card's cursor is still its own
  # place in the search (window_cursors is keyed by id over every row
  # fetched), so paging from it skips nothing and repeats nothing; the
  # row-count questions (#truncated?) ask the rows, not the cards.
  def posts
    @posts ||= post_set.posts.select { |post| PostPreviewComponent.listed?(post, viewer, show_deleted: post_set.show_deleted?) }
  end

  def query_string
    post_set.tag_string.to_s.strip
  end

  # The facet tags this viewer may be shown: banished names withheld from
  # all but the pipeline. See TagBanishment.
  def visible_sidebar_tags
    @visible_sidebar_tags ||= begin
      tags = post_set.sidebar_tags
      shown = TagBanishment.filter(tags.map(&:name), viewer).to_set
      tags.select { |t| shown.include?(t.name) }
    end
  end

  # Facet tags grouped by category, in display order: [[key, [tags]], ...].
  def tag_groups
    grouped = visible_sidebar_tags.group_by { |t| category_key(t) }
    CATEGORY_ORDER.filter_map { |k| [k, grouped[k]] if grouped[k].present? }
  end

  # Flat unitag list: [[tag, category_key], ...] in the same category order.
  def unitag_list
    tag_groups.flat_map { |key, tags| tags.map { |t| [t, key] } }
  end

  def any_tags?
    visible_sidebar_tags.any?
  end

  # The gallery's card: PostCards#card_data with data-key, the card's place
  # in the search (PostNeighbors::Seek), which the gallery window pages
  # from; none where the viewer has no window. Second in the attributes, as
  # it always was, so the gallery's bytes do not move.
  def card_data(post)
    { "data-id" => post.id, "data-key" => post_set.window_cursors[post.id] }.merge(super)
  end

  # --- the pager ---------------------------------------------------------
  # Prev and next, and the count -- no page number: once each box depends on
  # the viewer's own blocklist a page number cannot be exact
  # (GALLERY_WINDOW.md section 2). The hrefs are the server's answer without
  # the script: next opens the first post past the box, prev the place a box
  # back (or the head). With it, gallery_window.js takes the click and moves
  # the box over the posts the blocklist lets render.

  delegate :post_count, :windowing?, :window_kind, to: :post_set

  def next_href
    return nil unless windowing?
    return routes.posts_path(tags: query_string.presence) if window_kind == :draw

    # The first CARD past the box (#posts, as drawn): its cursor is its own
    # place in the search, so the next box opens on the first post the
    # viewer was not shown. Never a cursor of a post not listed for them,
    # which would carry its id.
    cursor = post_set.window_cursors[posts[PostSets::Post::WINDOW_SLOTS]&.id]
    place_href(cursor) if cursor
  end

  def prev_href
    return nil unless windowing? && post_set.window_more_behind?

    place_href(post_set.window_prev_cursor)
  end

  # The search at a place, or at its head for nil. Through params: because
  # `anchor:` is a URL helper's own option, the #fragment.
  def place_href(cursor)
    routes.posts_path(tags: query_string.presence, params: { anchor: cursor }.compact)
  end

  # Why the pager cannot page, where that is not the account's one page
  # (which truncated? explains).
  def pager_note
    return nil if windowing? || !can_browse? || posts.empty?

    if post_set.window_kind == :refused
      "order:none has no order to page through. Fix: pick a sort to page through the results."
    else
      "This link pages by post id (page=#{post_set.page}). Fix: open the search without page= to browse it."
    end
  end

  # The excerpt: when a search IS a subject -- one tag with a wiki page, an
  # artist entry, or a pool -- upstream offers its summary behind a tab. Search
  # for a character and the page can say who they are; without it the search is
  # a wall of thumbnails with no answer to "what am I looking at".
  #
  # A banned artist's entry is withheld from every viewer who reaches the
  # page; below Approver the search itself answers 451 (PostsController#index,
  # PostSets::Post#banned_artist?).
  def excerpt
    if post_set.artist.present? && !post_set.artist.is_banned?
      @excerpt ||= { kind: "artist", title: post_set.artist.name.tr("_", " "), href: routes.artist_path(post_set.artist), body: post_set.artist.wiki_page&.body }
    elsif post_set.pool.present?
      @excerpt ||= { kind: "pool", title: post_set.pool.pretty_name, href: routes.pool_path(post_set.pool), body: post_set.pool.description }
    elsif post_set.wiki_page.present?
      @excerpt ||= { kind: "wiki", title: post_set.wiki_page.pretty_title, href: routes.wiki_page_path(post_set.wiki_page), body: post_set.wiki_page.body }
    end
  end

  # Whose original character a wiki excerpt is (CharacterClaim, OC ownership
  # 2026-10-11): { name:, href: } as this viewer may be told, nil otherwise.
  # One query for a claimable title, none for any other excerpt.
  def excerpt_owner
    return @excerpt_owner if defined?(@excerpt_owner)

    title = post_set.wiki_page&.title if excerpt&.dig(:kind) == "wiki"
    @excerpt_owner = title && CharacterClaim.owners([title], viewer)[title]
  end

  def can_browse?
    viewer.present? && viewer.can_browse_freely?
  end

  # Shown when there are more results than this viewer is allowed to page
  # through, so the cut-off is explained where it happens rather than being
  # discovered as a missing button.
  #
  # Asked of the ROWS the page fetched (post_set.posts), not the cards drawn
  # (#posts): a page whose 20 rows held one post not listed for the viewer
  # draws 19 cards, and is still a full page with a 21st row past it.
  def truncated?
    return false if can_browse?

    rows = post_set.posts.size
    return false if rows < post_set.per_page

    # A further post THIS viewer may see, not the count: a tag's count includes
    # posts nobody at this level can see (operator, 2026-10-17), and a full
    # account would not show those either. Unordered: whether a 21st row exists
    # does not depend on the order, and order:random would sort every matching
    # row (the page itself samples instead; PostQueryBuilder#paginated_posts).
    # The query the page was fetched from, so the probe and the page count
    # the same rows.
    post_set.window_query.posts.reorder(nil).offset(rows).limit(1).pluck(:id).any?
  end
end
