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

  def board_href(board)
    rest = query_terms.reject { |t| BOARDS.any? { |b| b[:source] == t.downcase } }
    rest << board[:source] unless board_active?(board)
    routes.posts_path(tags: rest.join(" ").presence)
  end

  # `settings` is the viewer's Modulation view state (ModulationSetting.for_viewer);
  # the panel renders its remembered sort, view and deleted toggle from it.
  def initialize(post_set:, viewer:, settings: nil)
    super
    @post_set = post_set
    @viewer = viewer
    @settings = settings || ModulationSetting.defaults
  end

  attr_reader :settings

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
  # place past them.
  delegate :posts, to: :post_set

  def query_string
    post_set.tag_string.to_s.strip
  end

  # The post view link, carrying the search so its nav follows this exact search.
  def post_link(post)
    routes.post_path(post, q: query_string.presence)
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

  # Blacklist rules are matched client-side against these attributes, so every
  # card has to carry them or the viewer's blacklist silently does not apply --
  # which is what happened for as long as this gallery rendered bare <a> cards
  # and the blacklist's selector list knew nothing about them.
  #
  # data-tags comes from FourierTagSource.blacklist_tags_for, NOT post.tag_string:
  # tag_string still holds the private creator tags, and this is the default view
  # of the site.
  #
  # data-key is the card's place in the search (PostNeighbors::Seek), which
  # the gallery window pages from; none where the viewer has no window.
  def card_data(post)
    {
      "data-id" => post.id,
      "data-key" => post_set.window_cursors[post.id],
      "data-tags" => blacklist_tags[post].to_a.join(" "),
      "data-rating" => post.rating,
      "data-flags" => post.status_flags,
      "data-score" => post.score,
      "data-uploader-id" => post.uploader_id,
      "data-tag-marks" => card_tag_marks.fetch(post.id, {}).to_json,
    }
  end

  # Each card's tags, for the hover panel: name -> [bucket, lamp], the same
  # two answers the facet pills get, per post rather than per page. Public
  # rows, one pluck for the page. A tag with no row is left out -- the panel
  # draws it unsourced with a white lamp, which is what no row means.
  #
  # Fork: only rows for a tag the card carries (card_tags). A row stays
  # behind when its tag leaves the post -- a hand edit, a bulk update and the
  # private-tag cleanup write tag_string, never the sidecar -- and such a
  # dormant row is provenance for nothing here; its name was written into
  # the page source all the same (BUR review 2026-10-19).
  def card_tag_marks
    @card_tag_marks ||= FourierTagSource.publicly_visible
      .where(post_id: posts.map(&:id))
      .pluck(:post_id, :tag, :source, :status)
      .select { |post_id, tag, _, _| card_tags.fetch(post_id, Set.new).include?(tag) }
      .group_by(&:first)
      .transform_values do |rows|
        rows.to_h { |_, tag, source, status| [tag, [provenance_bucket(source, status == FourierTagSource::PENDING), FourierTagSource.lamp_of(source).to_s]] }
      end
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for(posts, viewer)
  end

  # Fork: post id -> the Set of tags its card carries (data-tags), which a
  # provenance row must name to count for that card.
  def card_tags
    @card_tags ||= posts.to_h { |post| [post.id, blacklist_tags[post].to_a.to_set] }
  end

  def thumb_for(post)
    post.visible?(viewer) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  # name -> category key for every tag on this page's cards, one batched
  # lookup (Tag.categories_for is a memcache multi-get -- never per-card).
  # Built from the same gated projection as data-tags, then banished names
  # are withheld: the map doubles as the hover panel's DISPLAY gate, so the
  # client shows only tags it can find here and never learns the banished
  # vocabulary at all.
  def page_tag_categories
    @page_tag_categories ||= begin
      names = TagBanishment.filter(blacklist_tags.values.flatten.uniq, viewer)
      ints = Tag.categories_for(names)
      keys = {
        TagCategory::ARTIST => "artist",
        TagCategory::COPYRIGHT => "copyright",
        TagCategory::CHARACTER => "character",
        TagCategory::META => "meta",
      }
      names.index_with { |n| keys[ints[n]] || "general" }
    end
  end

  # name -> post count, for the same names the category map admits (operator
  # ruling 2026-09-07: the hover panel shows each tag's count after it). One
  # query for the page, never one per tag, and keyed off page_tag_categories so
  # a banished name cannot reappear here after being withheld there.
  def page_tag_counts
    @page_tag_counts ||= begin
      names = page_tag_categories.keys
      counts = names.any? ? Tag.where(name: names).pluck(:name, :post_count).to_h : {}
      names.index_with { |n| counts[n].to_i }
    end
  end

  # The card's bottom-right credit: the post's first artist tag, if the
  # viewer may see one.
  def artist_for(post)
    blacklist_tags[post].to_a.find { |t| page_tag_categories[t] == "artist" }
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

  # "Related": the same search seen another way. Deliberately only the ones that
  # act on the CURRENT query -- the upstream list mixes those with global
  # discovery links, and mixing them is why that section reads as a junk drawer.
  # There is no deleted TOGGLE any more (operator ruling 2026-09-07): viewing
  # deleted posts is its own search, asked for with `status:deleted` the way
  # anything else is asked for. What the gallery draws still follows
  # post_set.show_deleted?, which upstream derives from that search -- so the
  # rule is now in one place instead of two disagreeing ones.

  def forum_enabled?
    Danbooru.config.forum_enabled?.to_s.truthy?
  end

  def single_tag
    return nil unless post_set.post_query.has_single_tag?

    post_set.post_query.tag_name
  end

  def can_save_search?
    # Not ApplicationComponent#policy: that delegates to a current_user method
    # this component does not have -- it takes its viewer explicitly, because it
    # is also built outside a request in the navigation payload path.
    SavedSearchPolicy.new(viewer, SavedSearch).create?
  end

  # The excerpt: when a search IS a subject -- one tag with a wiki page, an
  # artist entry, or a pool -- upstream offers its summary behind a tab. Search
  # for a character and the page can say who they are; without it the search is
  # a wall of thumbnails with no answer to "what am I looking at".
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

  def can_browse?
    viewer.present? && viewer.can_browse_freely?
  end

  # Shown when there are more results than this viewer is allowed to page
  # through, so the cut-off is explained where it happens rather than being
  # discovered as a missing button.
  def truncated?
    return false if can_browse?
    return false if posts.size < post_set.per_page

    # A further post THIS viewer may see, not the count: a tag's count includes
    # posts nobody at this level can see (operator, 2026-10-17), and a full
    # account would not show those either. Unordered: whether a 21st row exists
    # does not depend on the order, and order:random would sort every matching
    # row (the page itself samples instead; PostQueryBuilder#paginated_posts).
    post_set.normalized_query.posts.reorder(nil).offset(posts.size).limit(1).pluck(:id).any?
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  # PROVENANCE, for the page. name -> "creator" | "both" | "auto" | "meta" |
  # "pending", for every sidebar tag that has a public provenance row on a
  # post of this page that carries it; a name with none is unsourced. One
  # query for the page: the OR of the source flags says who put the name
  # there anywhere on the page, which is the honest answer for a list that
  # aggregates the page. Public rows only -- the sidebar's names come from
  # tag_string, which never holds a private creator tag, so a private row
  # could only ever add information this viewer may not have.
  #
  # Fork: and only rows whose tag the post still carries (card_tags). A row
  # left behind when its tag left its post coloured every other card's pill
  # for that name (BUR review 2026-10-19).
  #
  # And THE LAMP, from the same OR: which model put the name there
  # anywhere on the page (FourierTagSource.lamp_of) -- the pill's dot, per
  # formant. name -> [bucket, lamp]; a name with no row is unsourced, manual.
  def page_tag_provenance
    @page_tag_provenance ||= begin
      names = page_tag_categories.keys
      if names.empty? || posts.empty?
        {}
      else
        FourierTagSource.publicly_visible
          .where(post_id: posts.map(&:id), tag: names)
          .pluck(:post_id, :tag, :source, :status)
          .select { |post_id, tag, _, _| card_tags.fetch(post_id, Set.new).include?(tag) }
          .group_by { |_, tag, _, _| tag }
          .to_h do |tag, rows|
            source = rows.map { |_, _, bits, _| bits }.reduce(0, :|)
            pending = rows.all? { |_, _, _, status| status == FourierTagSource::PENDING }
            [tag, [provenance_bucket(source, pending), FourierTagSource.lamp_of(source)]]
          end
      end
    end
  end

  def provenance_bucket(source, pending)
    return "pending" if pending
    return "meta" if source & FourierTagSource::META > 0
    return "both" if source & FourierTagSource::CREATOR > 0 && source & FourierTagSource::AUTO > 0
    return "creator" if source & FourierTagSource::CREATOR > 0

    "auto"
  end

  # The pill's classes: provenance paints it, category only for the
  # identifying kinds (the post page's rule; the stylesheet's compound
  # category selector is what makes artist/character/copyright win).
  def pill_classes(tag)
    "mod-pill mod-pill--#{page_tag_provenance.dig(tag.name, 0) || 'unsourced'} mod-pill--cat mod-pill--cat-#{category_key(tag)}"
  end

  # The dot's lamp class. No row: no model, a person's white lamp.
  def dot_classes(tag)
    "mod-pill-dot mod-pill-dot--#{page_tag_provenance.dig(tag.name, 1) || :manual}"
  end

  def category_key(tag)
    return "artist" if tag.artist?
    return "copyright" if tag.copyright?
    return "character" if tag.character?
    return "meta" if tag.meta?

    "general"
  end
end
