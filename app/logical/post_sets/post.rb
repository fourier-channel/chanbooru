# frozen_string_literal: true

# A PostSet is a set of posts returned by a search.  This contains helper
# methods used on the post index page.
#
# @see PostsController#index
module PostSets
  class Post
    extend Memoist

    MAX_SIDEBAR_TAGS = 25
    MAX_WILDCARD_TAGS = PostQueryBuilder::MAX_WILDCARD_TAGS

    # THE GALLERY WINDOW (GALLERY_WINDOW.md section 2). The Modulation grid is
    # a box of WINDOW_SLOTS -- 5 x 4, 4 x 5, 2 x 10 -- over the search's
    # results, filled by the posts the viewer's blocklist lets render; the
    # browser holds a run of results beyond the box and fetches more in
    # chunks from a cursor (PostNeighbors::Seek). The page is drawn with
    # WINDOW_CHUNK posts, so a blocklist that hides some still fills the box;
    # a chunk asks for WINDOW_CHUNK..WINDOW_CHUNK_MAX, more when the
    # blocklist is hiding more.
    WINDOW_SLOTS = 20
    WINDOW_CHUNK = 40
    WINDOW_CHUNK_MAX = 100

    attr_reader :current_user, :page, :format, :tag_string, :post_query, :normalized_query, :show_votes, :window, :anchor, :before

    alias_method :show_votes?, :show_votes

    # The single tag searched for -- nil when its name is hidden from the
    # viewer (Tag#hidden_from?: a quarantined name, TagQuarantine), as
    # RelatedTagQuery#tag does, so a typed hidden name shows no excerpt, wiki
    # notice, alias list or tag-change notice: 0 results, as for a name never
    # used. wiki_page and artist follow it.
    def tag
      found = post_query.tag
      found unless found.nil? || found.hidden_from?(current_user)
    end
    memoize :tag

    # @param window [Symbol, nil] the Modulation gallery: :page for the page
    #   it draws, :chunk for a run the window fetches (variant=window); nil
    #   everywhere else, which pages as upstream does
    # @param anchor [String, nil] a cursor: the window starts AT this place
    # @param before [String, nil] a cursor: the chunk ends just before it
    def initialize(tags, page = 1, per_page = nil, user: CurrentUser.user, format: "html", show_votes: false, window: nil, anchor: nil, before: nil) # rubocop:disable Metrics/ParameterLists
      @current_user = user
      @tag_string = tags
      @format = format.to_s
      @post_query = PostQuery.normalize(tags, current_user: user, tag_limit: user.tag_query_limit, safe_mode: CurrentUser.safe_mode?)
      @normalized_query = post_query.with_implicit_metatags
      @page = page
      @per_page = per_page
      @show_votes = show_votes
      @window = window
      @anchor = anchor.presence
      @before = before.presence
    end

    # The title of the page for the <title> tag.
    def page_title
      post_query.to_pretty_string
    end

    # The description of the page for the <meta name="description"> tag.
    def meta_description
      # XXX post_count may be nil if the search times out because of safe mode
      if post_query.is_simple_tag? && post_count.present?
        humanized_count = ApplicationController.helpers.humanized_number(post_count, million: " million", thousand: " thousand")
        humanized_count = "over #{humanized_count}" if post_count >= 1_000

        "See #{humanized_count} #{page_title} images on #{Danbooru.config.app_name}. #{DText.new(wiki_page&.body).excerpt}"
      else
        Danbooru.config.site_description
      end
    end

    def has_blank_wiki?
      tag.present? && wiki_page.nil?
    end

    def wiki_page
      return nil unless post_query.has_single_tag?
      return nil if post_query.tag.present? && tag.nil?

      @wiki_page ||= WikiPage.undeleted.find_by(title: post_query.tag_name)
    end

    def artist
      return nil unless tag.present? && tag.artist?
      return nil unless tag.artist.present? && !tag.artist.is_deleted?
      tag.artist
    end

    def pool
      pool_names = post_query.select_metatags(:pool, :ordpool).map(&:value)
      name = pool_names.first
      return nil unless pool_names.size == 1

      @pool ||= Pool.find_by_name(name)
    end

    def favgroup
      favgroup_names = post_query.select_metatags(:favgroup, :ordfavgroup).map(&:value)
      name = favgroup_names.first
      return nil unless favgroup_names.size == 1

      @favgroup ||= FavoriteGroup.visible(CurrentUser.user).find_by_name_or_id(name, CurrentUser.user)
    end

    def has_explicit?
      posts.any? { |x| x.rating == "e" }
    end

    def hidden_posts
      posts.reject(&:visible?)
    end

    def banned_posts
      posts.select(&:banblocked?)
    end

    def censored_posts
      posts.select { |p| p.levelblocked? && !p.banblocked? }
    end

    def safe_posts
      posts.select { |p| p.safeblocked? && !p.levelblocked? && !p.banblocked? }
    end

    # In the Modulation gallery the window sizes the page, not the account's
    # "posts per page" or a limit: term: the box is WINDOW_SLOTS whatever
    # they say, and the run behind it is the window's to size.
    #
    # Clamped to the viewer's page (User#listing_per_page_limit) here as well
    # as in paginate, because it is read before the query: the Random
    # button's random:N and the gallery's cut-off note.
    def per_page
      if window && windowing?
        (window == :chunk) ? (@per_page || WINDOW_CHUNK).to_i.clamp(WINDOW_CHUNK, WINDOW_CHUNK_MAX) : WINDOW_CHUNK
      elsif window
        [WINDOW_SLOTS, current_user.listing_per_page_limit].min
      else
        (@per_page || post_query.find_metatag(:limit) || current_user.per_page).to_i.clamp(0, current_user.listing_per_page_limit)
      end
    end

    def posts
      post_query.validate_tag_limit!
      check_window!
      # A chunk counts nothing: the page it extends already showed the count.
      # Except a random draw, where the count is what decides between a true
      # shuffle and a sample (PostQueryBuilder#paginated_posts). Nor does the
      # md5 ask (#md5_ask?): its answer is its rows.
      count = ((window == :chunk && window_kind != :draw) || md5_ask?) ? nil : post_count
      # viewer: this set is handed a user, and is built outside a request in
      # tests; paginate asks it, not CurrentUser, for the browsing tier.
      window_query.paginated_posts(page, includes: includes, count: count, search_count: !count.nil?, limit: per_page, seek: seek, viewer: current_user).load
    end

    # Whether this set is the window: the Modulation gallery, for a viewer who
    # may browse, under an order with a place to keep -- or a random draw,
    # which the window extends with fresh draws. An old `page=b<id>` link is
    # served as it always was, outside the window. This decides what is
    # DRAWN; a cursor is refused below the tier by paginate (#seek).
    def windowing?
      window.present? && current_user.can_browse_freely? && window_kind != :refused && !page.to_s.match?(/\A[ab]\d+\z/i)
    end

    # FOURIER-AUTH'S MD5 ASK (booru-visibility.js): tags=md5:<1-20 hashes>,
    # in json or xml, asked for every image the media gate serves, signed out
    # and then as the reader. Fork, incident 2026-10-19: built as a gallery,
    # each ask plucked every hidden creator-prefix post id (~69,600, 0.4 s),
    # compiled them into a ~530 KB literal and ran an exact COUNT keyed on its
    # batch, so never cached -- 0.5-1.1 s around a 15 ms SELECT -- and 78 asks
    # passed fourier-auth's 4 s budget and were refused. Built instead with
    # no count. Its hidden tags are the row filter every implicit search
    # carries since 2026-10-24 (PostQuery#hidden_tags_condition), and its
    # rows, 20 at most, come off the md5 index, so the filter runs on those
    # rows alone (md5_ask_test's parity table). Signed out, the
    # answer still passes MembersOnly.anonymous_md5_rows (PostsController).
    def md5_ask?
      format.in?(%w[json xml]) && tag_string.to_s.strip.match?(MembersOnly::ANONYMOUS_MD5_QUERY)
    end

    # PostNeighbors::Seek.kind of this search's order: :key, :offset, :draw
    # or :refused.
    def window_kind
      PostNeighbors::Seek.kind(effective_order)
    end

    delegate :effective_order, to: :normalized_query

    # The search the window pages. A deleted post is dropped HERE, in the
    # query, for every viewer who did not ask for deleted posts -- below the
    # deleted-visibility level deleted_metatags already did -- rather than at
    # render: a chunk that fetched a page of deleted posts would draw nothing
    # and name no cursor past them.
    def window_query
      return normalized_query if window.nil? || show_deleted? || !current_user.can_see_deleted_posts?

      normalized_query.build(PostQuery::AST.new(:and, [normalized_query.ast, -PostQuery::AST.metatag("status", "deleted")]))
    end

    # The cursor this set pages from: an anchor, a before, an old `page=N`
    # read as the position it showed, or the head of the search. nil outside
    # the window and for a random draw.
    #
    # An anchor or a before becomes a seek for EVERY viewer, so a viewer below
    # the browsing tier is refused by paginate (a seek that names a place),
    # never handed page 1 for a cursor (ACCOUNT_LIMITS.md section 4).
    def seek
      return nil if window.nil? || window_kind == :draw || page.to_s.match?(PaginationExtension::CURSOR)
      return nil unless windowing? || anchor || before

      direction = before ? :backward : :forward
      cursor = anchor || before
      cursor ||= "@#{(current_page - 1) * WINDOW_SLOTS}" if current_page > 1
      found = cursor ? PostNeighbors::Seek.parse(effective_order, cursor, direction: direction) : PostNeighbors::Seek.head(effective_order)
      found.resolve(window_query.posts)
    end

    # A cursor this set cannot keep is refused by name (422), never read as
    # page 1: two at once, a cursor under order:random (a fresh draw every
    # look) or order:none (no order at all).
    def check_window!
      return if window.nil? || (anchor.nil? && before.nil?)

      raise PostNeighbors::NoPlace, "anchor= and before= cannot be used together. Fix: keep one of them." if anchor && before

      PostNeighbors::Seek.refuse_kind!(effective_order)
    end

    # Each drawn post's cursor, by id: its key under a key sort, its
    # position under any other.
    def window_cursors
      return {} unless seek

      if seek.spec && seek.offset.nil?
        posts.to_h { |post| [post.id, PostNeighbors::Seek.mint(post, effective_order)] }
      else
        posts.each_with_index.to_h { |post, i| [post.id, "@#{window_start + i}"] }
      end
    end

    # The position of the first drawn post, for a position-based page.
    def window_start
      seek.backward? ? [seek.offset - per_page, 0].max : seek.offset
    end

    # Whether the search goes on past the last drawn post. A random draw has
    # no place, so more is whether it came back full: one that came back
    # short held the whole set. Never the count, which reads the search as
    # typed (PostQuery#estimated_count), not what this viewer can see.
    def window_more_ahead?
      return false unless windowing?
      return posts.size >= per_page if seek.nil?

      seek.backward? || posts.more?
    end

    # Whether the search holds posts before the first drawn one.
    def window_more_behind?
      return false unless seek

      seek.backward? ? posts.more? : !window_behind[:head]
    end

    # Where "prev" goes without the script: the place WINDOW_SLOTS posts back,
    # or nil for the head of the search (a short way back lands on the head).
    def window_prev_cursor
      window_behind[:cursor]
    end

    # One look back from the first drawn post: WINDOW_SLOTS ids and keys, so
    # it answers both whether this is the head and where prev lands.
    def window_behind
      return { head: true } if seek.nil? || (seek.id.nil? && seek.offset.to_i == 0 && !seek.backward?)

      if seek.spec.nil? || (seek.offset && posts.empty?)
        start = window_start
        { head: start == 0, cursor: ("@#{start - WINDOW_SLOTS}" if start > WINDOW_SLOTS) }
      else
        first = posts.first
        spec = seek.spec
        from = first ? [first.id, PostNeighbors::Seek.key_of(spec, spec.value.call(first))] : [seek.id, seek.key]
        back = PostNeighbors::Seek.new(spec: spec, id: from[0], key: from[1], direction: :backward)
        rows = back.apply(window_query.posts).limit(WINDOW_SLOTS).pluck(Arel.sql("posts.id"), Arel.sql(spec.column))
        far = rows.last
        { head: rows.empty?, cursor: ("#{far[0]}~#{PostNeighbors::Seek.key_of(spec, far[1])}" if rows.size == WINDOW_SLOTS) }
      end
    end

    # @return [Integer, nil] The number of posts returned by the search, or nil if unknown.
    def post_count
      return 0 if artist.present? && artist.is_banned? && !current_user.is_approver?
      normalized_query.post_count
    end

    def hide_from_crawler?
      return true if current_page > 50
      return true if show_votes?
      return true if artist.present? && artist.is_banned?
      return false if post_query.is_empty_search? || post_query.is_simple_tag? || post_query.is_metatag?(:order, :rank)
      true
    end

    def current_page
      [page.to_i, 1].max
    end

    def best_post
      posts.reject(&:is_deleted).select(&:visible?).max_by { |post| [-post.rating_id, post.score] }
    end

    # Whether this search may surface deleted posts.
    #
    # The level check is first and is not an extra safeguard -- it is the only
    # real one. Everything after it is the VIEWER asking: show_deleted_posts? is
    # an account preference they set themselves, and has_status_metatag? is
    # literally them typing status:deleted into the search box. Upstream ORs
    # those two together and stops, so on a stock Danbooru any visitor, signed
    # out included, can list every deleted post by asking for it.
    #
    # Which is why hiding the settings toggle would have achieved nothing here.
    # The toggle was never the way in; the search box was.
    def show_deleted?
      return false unless current_user.can_see_deleted_posts?

      current_user.show_deleted_posts? || has_status_metatag?
    end

    def has_status_metatag?
      post_query.select_metatags("is", "status").any? do |metatag|
        metatag.value.downcase.in?(%w[all any active unmoderated modqueue deleted appealed])
      end
    end

    def banned_artist?
      artist.present? && artist.is_banned? && !current_user.is_approver?
    end

    def includes
      if show_votes?
        [:media_asset, :vote_by_current_user]
      else
        [:media_asset]
      end
    end

    concerning :TagListMethods do
      # @return [Array<Tag>] The list of tags for the sidebar on the post index page.
      #
      # Fork: without the names hidden from this viewer (Tag.hidden_names_for,
      # as /tags and related tags leave them out). The sidebar is drawn from
      # the posts on the page, and below Gold that page can hold a gated post
      # -- the viewer's own upload, or one its creator let them in to -- whose
      # gated name is shown on that post's own tag list and in no listing
      # (operator, 2026-10-14: gated tag names follow the post).
      #
      # And a list of tags, so at most the viewer's page
      # (User#listing_per_page_limit): a wildcard drew 100 of them for a viewer
      # /tags holds to 20.
      def sidebar_tags
        hidden = Tag.hidden_names_for(current_user, by_creator: false).to_set
        if artist.present? && artist.is_banned? && !current_user.is_approver?
          []
        elsif normalized_query.wildcards.one? && normalized_query.tags.none?
          wildcard_tags
        elsif normalized_query.is_metatag?(:search)
          saved_search_tags
        elsif normalized_query.is_empty_search? || normalized_query.is_metatag?(:order, :rank)
          tags = popular_tags.presence || frequent_tags
          tags.sort_by.with_index { |tag, i| [TagCategory.category_ids.index(tag.category), i] }
        elsif normalized_query.is_simple_tag? && tag.present?
          categories = TagCategory.search_sidebar_tag_categories[tag.category]
          tags = similar_tags(categories).presence || frequent_tags(categories)
          tags = [tag] + tags if !tag.in?(tags)
          sort_sidebar_tags(tags, categories)
        elsif normalized_query.is_single_term?
          sort_sidebar_tags(similar_tags.presence || frequent_tags)
        else
          sort_sidebar_tags(frequent_tags)
        end.reject { |tag| hidden.include?(tag.name) }.first(current_user.listing_per_page_limit)
      end

      # Sort the list of tags by category. For artist, character, and copyright tags, subsort them by post count. For
      # general and meta tags, leave them in the same order they were given in (similarity or frequency order).
      #
      # @param tags [Array<Tag>] the list of tags to sort
      # @param categories [Array<Integer>] the category order in which tags should be sorted by
      def sort_sidebar_tags(tags, categories = TagCategory.category_ids)
        tags.sort_by.with_index do |tag, i|
          [categories.index(tag.category) || -1, ([TagCategory::GENERAL, TagCategory::META].include?(tag.category) ? i : -tag.post_count)]
        end
      end

      # @return [Array<Tag>] the list of most frequently searched tags for the day.
      def popular_tags
        tag_names = ReportbooruService.new.popular_searches(Date.today, limit: MAX_SIDEBAR_TAGS)
        Tag.visible_to(current_user).where(name: tag_names).to_a.in_order_of(:name, tag_names)
      end

      # @return [Array<Tag>] the list of tags most related to the current search.
      #
      # Fork: none for a viewer whose search carries the hidden-tags row
      # filter, so the sidebar draws on the page's own posts. The calculator
      # samples the search as typed and caches it across viewers by that
      # string, so it would list what a jailed or hidden post carries -- the
      # leak RelatedTagQuery closed (2026-10-01). Until 2026-10-24 no such
      # viewer reached here: every one had a negated term the shape checks
      # saw (-troll_jail even for an admin), and the row filter is no term.
      def similar_tags(categories = TagCategory.category_ids)
        return [] if normalized_query.hidden_tags_condition
        RelatedTagCalculator.new(post_query).cached_similar_tags_for_search(MAX_SIDEBAR_TAGS, categories: categories)
      end

      # @return [Array<Tag>] the list of tags most frequently appearing in the current page of search results.
      def frequent_tags(categories = TagCategory.category_ids)
        RelatedTagCalculator.frequent_tags_for_post_array(posts, categories: categories, max_tags: MAX_SIDEBAR_TAGS)
      end

      # Wildcard searches can show up to 100 tags in the sidebar, not 25,
      # because that's how many tags the search itself will use.
      def wildcard_tags
        Tag.visible_to(current_user).wildcard_matches(post_query.wildcards.first).limit(MAX_WILDCARD_TAGS).to_a
      end

      def saved_search_tags
        searches = ["search:all"] + SavedSearch.labels_for(CurrentUser.user.id).map { |x| "search:#{x}" }
        searches.take(MAX_SIDEBAR_TAGS).map do |search|
          Tag.new(name: search).freeze
        end
      end
    end

    memoize :page_title, :posts, :seek, :window_kind, :effective_order, :window_query, :window_cursors, :window_behind
  end
end
