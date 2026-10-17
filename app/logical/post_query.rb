# frozen_string_literal: true

class PostQuery
  extend Memoist

  class Error < StandardError; end
  class TagLimitError < Error; end

  # Metatags that don't count against the user's tag limit.
  UNLIMITED_METATAGS = %w[
    status rating limit is id date age filesize filetype parent child md5 width
    height duration mpixels ratio score upvote downvotes favcount embedded
    tagcount pixiv_id pixiv holds
  ]

  # Metatags that define the order of search results. These metatags can't be used more than once per query.
  ORDER_METATAGS = %w[order ordfav ordvote ordfavgroup ordpool]

  # Metatags that can't be used more than once per query, and that can't be used with OR or NOT operators.
  SINGLETON_METATAGS = ORDER_METATAGS + %w[limit random]

  attr_reader :current_user
  private attr_reader :tag_limit, :safe_mode, :builder

  delegate :tag?, :metatag?, :wildcard?, :metatags, :wildcards, :tag_names, :to_infix, :to_pretty_string, to: :ast
  alias_method :safe_mode?, :safe_mode
  alias_method :to_s, :to_infix

  # @param search [String] The search string.
  # @param apply_aliases [Boolean] Whether aliased tags should be resolved.
  # @return [PostQuery] A new PostQuery for the search.
  def self.normalize(search, apply_aliases: true, **options)
    search = search.to_s.strip

    # Optimize zero tag and single tag searches
    if search.blank?
      PostQuery.new(AST.all, **options)
    elsif search.match?(%r{\A[a-zA-Z0-9][a-zA-Z0-9();/+!?&'._~-]*\z}) && !search.downcase.in?(["and", "or"])
      post_query = PostQuery.new(AST.tag(search), **options)
      apply_aliases ? post_query.replace_aliases : post_query
    else
      post_query = PostQuery.new(search, **options)
      post_query = post_query.replace_aliases if apply_aliases
      post_query.rewrite_opts.trim
    end
  end

  # Perform a search and return the resulting posts
  def self.search(search, ...)
    post_query = PostQuery.normalize(search, ...)
    post_query.validate_tag_limit!
    post_query.with_implicit_metatags.posts
  end

  # @param estimated [AST, nil] for a query #with_implicit_metatags made: the
  #   search as typed, with safe mode's terms but none of the viewer's, which
  #   #estimated_count reads (see there).
  def initialize(search_or_ast, current_user: User.anonymous, tag_limit: nil, safe_mode: false, implicit: false, estimated: nil)
    if search_or_ast.is_a?(AST)
      @ast = search_or_ast
    else
      @search = search_or_ast.to_s
    end

    @current_user = current_user
    @tag_limit = tag_limit
    @safe_mode = safe_mode
    @implicit = implicit
    @estimated = estimated
  end

  # Build a new PostQuery from the given AST and the current settings.
  def build(ast)
    PostQuery.new(ast, current_user: current_user, tag_limit: tag_limit, safe_mode: safe_mode, implicit: @implicit)
  end

  def builder
    @builder ||= PostQueryBuilder.new(self, current_user, tag_limit: tag_limit, safe_mode: safe_mode)
  end

  def search
    @search ||= ast.to_infix
  end

  def ast
    @ast ||= Parser.parse(search, metatags: PostQueryBuilder::METATAGS)
  end

  # matrix_rooms: false leaves out gate 3's row filter (#matrix_rooms_condition)
  # -- for the counts alone, which stay as they are (operator, 2026-10-15).
  def posts(matrix_rooms: true)
    validate_metatags!
    builder.posts(to_cnf, matrix_rooms: matrix_rooms)
  end

  def paginated_posts(...)
    validate_metatags!
    builder.paginated_posts(to_cnf, ...)
  end

  # Perform a search and return N posts, or none if the search times out.
  #
  # @param n [Integer] The number of posts to return.
  # @param timeout [Integer] The search timeout, in milliseconds.
  # @param count [Integer] The number of posts matched by the search. An optional optimization if the search count is known ahead of time.
  # @return [Array<Post>]
  def posts_with_timeout(n, timeout: current_user.statement_timeout, count: post_count, **options)
    Post.with_timeout(timeout, []) do
      paginated_posts(1, limit: n, count: count, **options).to_a
    end
  end

  # The name of the only tag in the query, if the query contains a single tag. The tag may not exist. The query may contain other metatags or wildcards, and the tag may be negated.
  def tag_name
    tag_names.first if has_single_tag?
  end

  # The only tag in the query, if the query contains a single tag. The query may contain other metatags or wildcards, and the tag may be negated.
  def tag
    tags.to_a.first if has_single_tag?
  end

  # The list of all tags contained in the query.
  def tags
    Tag.where(name: tag_names)
  end

  # The only pool in the query, if the query contains a single pool.
  def pool
    Pool.find_by_name(find_metatag(:pool)) if is_single_pool?
  end

  # True if this search would return all posts (normally because the search is the empty string).
  def is_empty_search?
    ast.all?
  end

  # True if this search would return nothing (normally because there was a syntax error).
  def is_null_search?
    ast.none?
  end

  # True if the search is a single, non-negated metatag search for the given metatag. Assumes the query has been normalized.
  def is_metatag?(name, value = nil)
    if value.nil?
      metatag? && has_metatag?(name)
    else
      metatag? && find_metatag(name) == value.to_s
    end
  end

  # True if the search consists of a single tag, metatag, or wildcard.
  def is_single_term?
    tag_names.size + metatags.size + wildcards.size == 1
  end

  # True if this search consists only of a single non-negated tag, with no other metatags or operators.
  def is_simple_tag?
    ast.tag?
  end

  # True if the search contains a single tag. It may have other metatags or wildcards, and the tag may be negated.
  def has_single_tag?
    tag_names.one?
  end

  def is_single_pool?
    is_metatag?(:pool)
  end

  # True if the search depends on the current user because of permissions or privacy settings.
  def is_user_dependent_search?
    metatags.any? do |metatag|
      # XXX date: is user dependent because it depends on the current user's time zone
      metatag.name.in?(%w[date upvoter upvote downvoter downvote commenter comm search flagger fav ordfav ordvote favgroup ordfavgroup]) ||
      metatag.name == "status" && metatag.value == "unmoderated" ||
      metatag.name == "disapproved" && !metatag.value.downcase.in?(PostDisapproval::REASONS)
    end
  end

  def select_metatags(*names)
    metatags.select { |metatag| metatag.name.in?(names.map(&:to_s).map(&:downcase)) }
  end

  def has_metatag?(*names)
    select_metatags(*names).present?
  end

  def find_metatag(*names)
    select_metatags(*names).first&.value
  end

  # Return a new PostQuery with unnecessary AND and OR clauses eliminated.
  def trim
    build(ast.trim)
  end

  # Return a new PostQuery with the '~' operator replaced with OR clauses.
  def rewrite_opts
    build(ast.rewrite_opts)
  end

  # Return a new PostQuery with aliases replaced.
  def replace_aliases
    return self if aliases.empty?
    build(ast.replace_tags(aliases))
  end

  # Return a new PostQuery with implicit metatags added.
  #
  # NOT -status:deleted, whatever this comment said before -- but not because
  # upstream stopped hiding deleted posts. It INVERTED the preference:
  # hide_deleted_posts (opt out, default show) was retired to
  # _unused_hide_deleted_posts, and show_deleted_posts (opt in, default hide)
  # took its place. Deleted posts are hidden by default; the surviving setting
  # is the one that reveals them.
  #
  # The hiding just does not happen here. It happens at the RENDER layer:
  # PostPreviewComponent#render? declines to draw a deleted post unless
  # show_deleted. So the query returns deleted posts and counts them, and the
  # page simply does not draw them -- which is why a page can report more
  # results than it shows.
  #
  # What IS added here: rating restrictions under safe mode, and this fork's
  # gated tags for signed-out visitors.
  #
  # And the viewer's own query is marked as such (implicit), which is what
  # brings gate 3's row filter with it (#matrix_rooms_condition).
  def with_implicit_metatags
    query = implicit_metatags.empty? ? ast : AST.new(:and, [ast, *implicit_metatags])
    estimated = safe_mode_metatags.empty? ? counted_ast : AST.new(:and, [counted_ast, *safe_mode_metatags])
    PostQuery.new(query, current_user: current_user, tag_limit: tag_limit, safe_mode: safe_mode, implicit: true, estimated: estimated)
  end

  # Orders that only re-sort the rows (Post.order_matches). An order that can
  # drop rows is not here: artcomm inner-joins the commentaries, and the count
  # columns join their stats.
  REORDER_ONLY_ORDERS = %w[
    id id_asc id_desc md5 md5_asc md5_desc score score_asc score_desc
    favcount favcount_asc created_at created_at_asc created_at_desc
    change change_asc change_desc mpixels mpixels_asc mpixels_desc
    filesize filesize_asc filesize_desc tagcount tagcount_asc tagcount_desc
    comment comment_asc comm comm_asc comment_bumped comment_bumped_asc
    note note_asc portrait landscape random
  ].freeze

  # The search with its re-sort-only order: terms taken out, for the count:
  # the gallery appends the viewer's remembered sort to every search
  # (PostsController#apply_modulation_panel_memory), and "landscape
  # order:id_desc" is no longer one tag, so no estimate applied and every
  # such count was an exact count over the whole table. order: is only ever
  # a top-level term (#validate_metatags! refuses it negated or OR-ed).
  def counted_ast
    reorder_only = ->(node) { node.metatag? && node.name == "order" && node.value.to_s.downcase.in?(REORDER_ONLY_ORDERS) }
    return AST.all if reorder_only.call(ast)
    return ast unless ast.and?

    kept = ast.children.reject(&reorder_only)
    kept.empty? ? AST.all : AST.new(:and, kept).trim
  end

  # GATE 3 FOR POSTS (fourier-basis docs/design/GATE3_MATRIX_POSTS.md;
  # Post#hidden_by_matrix_rooms?): a Matrix post is in the viewer's results
  # only when its rooms meet theirs. ONE row filter, `posts.room_ids &&
  # '{<viewer's set>}'::integer[]`, with the set INLINED as a literal -- not a
  # bound parameter, not a subquery -- beside the tag condition, so it
  # composes with any search in one query; and no index on room_ids, so the
  # planner keeps the tag or id plan and checks the overlap on the rows it
  # visits (measured 2026-10-15 at 1M Matrix posts in 10k rooms: <= 3 ms for
  # newest, common and rare tags, neighbours and post pages; <= 0.35 s for a
  # mid tag; with an index, 113 s). A post that is not a Matrix post carries
  # {0} and every set holds 0.
  #
  # NOT a metatag: the count cache is keyed by the query string, and counts
  # stay as they are (operator, 2026-10-15: "don't break the site
  # functionally over the potential of a tag count mismatch") -- so
  # CountMethods count without it, and one viewer's rooms never key a count.
  # Only the viewer's own query (#with_implicit_metatags) carries it.
  def matrix_rooms_condition
    return nil unless @implicit && MatrixViewerRooms.enforced_for?(current_user)

    "posts.room_ids && #{MatrixViewerRooms.literal(current_user)}"
  end

  # Return a new PostQuery with terms sorted into alphabetical order.
  def sort
    build(ast.sort)
  end

  # Return a new PostQuery converted to conjunctive normal form.
  def to_cnf
    build(ast.to_cnf)
  end

  # Return a hash mapping aliased tag names to real tag names.
  # Fork: an alias or abbreviation whose target is a quarantined name hidden
  # from this viewer (TagQuarantine.hidden_names_for) is not applied: the
  # resolved search is echoed back -- the page title, the canonical link,
  # the History link, the random redirect -- and would name the hidden tag
  # to someone who typed only the alias. Unresolved, the typed name matches
  # what a name never used matches, and the hidden posts are excluded anyway.
  def aliases
    found = TagAlias.aliases_for(tag_names)
    return found if found.empty?

    hidden = TagQuarantine.hidden_names_for(current_user)
    hidden.empty? ? found : found.reject { |_antecedent, consequent| hidden.include?(consequent) }
  end

  # Implicit metatags are added by the viewer's situation rather than typed by
  # them: rating:g under safe mode, and the gated tags a viewer below Gold may
  # not know exist.
  def implicit_metatags
    safe_mode_metatags + gated_metatags + deleted_metatags + banished_metatags + hidden_post_metatags
  end

  # Posts hidden from this viewer BY ID, as ONE negated id term:
  #
  #   - under a creator prefix the list hides from them (CreatorPrefixes
  #     visible_to; operator, 2026-10-07);
  #   - hidden by their creator's panel (CreatorVisibility; design
  #     CREATOR_VISIBILITY section 6, ruled 2026-10-07: excluded at QUERY
  #     level, from results, the count, the paginator and the neighbours, as
  #     gate 1 is);
  #   - carrying a FLAGGED tag they may not see (TagQuarantine, operator
  #     rulings 2026-10-12; a posting bot keeps its own uploads).
  #
  # By id rather than by tag: measured on production, excluding two tags made
  # an exact count of every post take 7.9s instead of 0.2s, past the count
  # timeout, while excluding their 101 post ids cost 0.09s. One term rather
  # than one per rule (fourier-sampling-c2's check, 2026-10-08): a post hidden
  # for both reasons is listed once, and the planner sees one NOT IN. As a
  # metatag, so the count cache key carries it and one viewer's count is never
  # served to another. Both lists are computed once per request per viewer.
  def hidden_post_metatags
    ids = (CreatorPrefixes.hidden_post_ids_for(current_user) | CreatorVisibility.hidden_ids(current_user).to_a | TagQuarantine.hidden_post_ids_for(current_user)).sort
    ids.empty? ? [] : [-AST.metatag("id", ids.join(","))]
  end

  def safe_mode_metatags
    return [] unless safe_mode?

    tags = Danbooru.config.safe_mode_restricted_tags.map { |tag| -AST.tag(tag) }
    [AST.metatag("rating", "g"), *tags]
  end

  # A deleted post is not in anyone's results unless they are allowed to see
  # deleted posts at all.
  #
  # Here rather than only in PostSets, because the operator's rule is that a
  # surface must not change the answer: the gallery, the API, a pool's contents
  # and a related-posts strip all run through this, and a filter applied only at
  # the place that draws thumbnails would leave the other three answering
  # honestly about something that is supposed to be gone.
  #
  # It also fixes the count, which the render-layer approach cannot: a page that
  # says "12 results" and draws 11 has told you the twelfth exists.
  #
  # Note the uploader is NOT excepted here. They reach their own deleted posts
  # by direct link, which is what an appeal needs; carving them out of the
  # search filter would mean building a per-viewer OR into every query to buy
  # something nobody asked for.
  def deleted_metatags
    return [] if current_user.blank? || current_user.can_see_deleted_posts?

    [-AST.metatag("status", "deleted")]
  end

  # A jailed or banished-tagged post is in nobody's results but the
  # pipeline's accounts (see
  # TagBanishment.withholds_posts_from?) -- status:deleted included, since
  # the terms are AND-ed onto whatever was asked. The query-level half of
  # Post#hidden_as_banished?, here for the reason deleted_metatags gives: a
  # filter over results never sees the count, the paginator or the
  # neighbours. See TagBanishment.withholds_posts_from?.
  def banished_metatags
    return [] unless TagBanishment.withholds_posts_from?(current_user)

    TagBanishment.post_tags.map { |tag| -AST.tag(tag) }
  end

  # Gate 1 (Post#hidden_as_gated?): gated posts are removed from the searches
  # of every viewer below Gold -- signed out, Restricted, Member (operator,
  # 2026-10-13) -- rather than listed with the image withheld.
  #
  # Here rather than in a filter over the results, because it has to hold for
  # things a filter never sees: the post COUNT, the paginator, "N posts", and
  # the neighbour lookups that drive post-to-post navigation. A row that is
  # excluded from the query cannot leak through any of them.
  #
  # A negated term per gated tag, the same shape and cost safe mode has
  # always had -- and, for a viewer nobody let in, exactly the terms a
  # signed-out visitor gets, so they share the count cache by the query
  # string. A viewer with gated posts of their own or a creator's allow
  # (Post.gated_allowed_ids) gets (-loli -shota ...) OR id:<theirs>, which
  # to_cnf turns into one clause per tag: "not this tag, or one of my ids" --
  # row filters on the rows the search visits, never a NOT IN over every
  # gated post. The id list is in the query, so in their count cache key.
  def gated_metatags
    return [] if Danbooru.config.restricted_tags.blank? || current_user&.is_gold?

    excluded = Danbooru.config.restricted_tags.map { |tag| -AST.tag(tag) }
    allowed = Post.gated_allowed_ids(current_user)
    allowed.empty? ? excluded : [AST.new(:or, [AST.new(:and, excluded), AST.metatag("id", allowed.sort.join(","))])]
  end

  concerning :CountMethods do
    extend Memoist

    # @return [Integer, nil] The number of posts returned by the search, or nil on timeout.
    def post_count
      @post_count ||= fast_count
    end

    # Return an estimate of the number of posts returned by the search. By default, we try to use an
    # estimated or cached count before doing an exact count.
    #
    # @param timeout [Integer] The database timeout in milliseconds
    # @param estimate_count [Boolean] If true, estimate the count with inexact methods.
    # @param skip_cache [Boolean] If true, don't use the cached count.
    # @return [Integer, nil] The number of posts, or nil on timeout.
    def fast_count(timeout: 1_000, estimate_count: true, skip_cache: false)
      count = nil
      count = estimated_count(timeout) if estimate_count
      count = cached_count(timeout) if count.nil? && !skip_cache
      count = exact_count(timeout) if count.nil? && skip_cache
      count
    end

    # @param timeout [Integer] The maximum amount of time to spend calculating the count.
    # @param exact_count_threshold [Integer] If the estimate is below this threshold, return an exact count instead.
    # @return [Integer, nil] The estimated post count, or nil if we can't compute a good estimate.
    #
    # Fork: the estimates read the search AS TYPED (@estimated), not with the
    # terms the viewer's situation adds (#implicit_metatags but safe mode's).
    # Counts are not a visibility surface (operator, 2026-10-17: "The tag
    # count doesn't need to be the same and it also doesn't need to be
    # different. It's a non issue altogether."), and with those terms no
    # search was ever one tag or blank, so every count of a popular search
    # was an exact count over the whole posts table: past the 1 s count
    # timeout, the page lost its count (production 2026-10-15..17: 263 of
    # 273 statement timeouts). A search the estimates do not cover -- id:,
    # md5:, several tags -- falls through to the exact count WITH the
    # viewer's terms, so a count never confirms one hidden post; and a tag
    # name hidden from the viewer counts 0, as a name never used does.
    def estimated_count(timeout = 1_000, exact_count_threshold: 20_000)
      return estimated_query.estimated_count(timeout, exact_count_threshold: exact_count_threshold) if estimated_query

      if is_simple_tag? && tag_name.in?(Tag.hidden_names_for(current_user, by_creator: false))
        # A gated name below Gold, for a viewer let in to some of its posts
        # (their own uploads, a creator's allow; #gated_metatags): counted
        # exactly over what they may see, never 0 beside rows they can see.
        (tag_name.in?(Danbooru.config.restricted_tags) && Post.gated_allowed_ids(current_user).any?) ? nil : 0
      elsif is_simple_tag? && CreatorVisibility.hidden_tag_names_among(current_user, [tag_name]).any?
        0
      elsif is_empty_search? || is_metatag?(:rating)
        # If there's a small number of posts, then the estimate may be noticeably off if the table hasn't been vacuumed
        # recently. Return the exact number of posts because calculating it is fast enough anyway.
        if estimated_row_count < exact_count_threshold
          exact_count(timeout)
        else
          estimated_row_count
        end
      elsif is_simple_tag?
        tag.try(:post_count)
      elsif (is_metatag?(:status) || is_metatag?(:is)) && metatags.sole.value.in?(%w[pending flagged appealed modqueue unmoderated])
        exact_count(timeout)
      elsif is_metatag?(:pool) || is_metatag?(:ordpool)
        name = find_metatag(:pool, :ordpool)

        if name.downcase.in?(Pool::RESERVED_NAMES)
          nil
        else
          Pool.find_by_name(name)&.post_count || 0
        end
      elsif is_metatag?(:fav) || is_metatag?(:ordfav)
        name = find_metatag(:fav, :ordfav)
        user = User.find_by_name(name)

        if user.nil?
          0
        elsif Pundit.policy!(current_user, user).can_see_favorites?
          user.favorite_count
        else
          nil
        end
      end
    end

    # The search as typed, for #estimated_count; nil on a query that is
    # already that.
    memoize def estimated_query
      PostQuery.new(@estimated, current_user: current_user, tag_limit: tag_limit, safe_mode: safe_mode) if @estimated
    end

    # Estimate the count by parsing the Postgres EXPLAIN output.
    memoize def estimated_row_count
      ExplainParser.new(posts(matrix_rooms: false)).row_count
    end

    def cached_count(timeout, duration: 5.minutes)
      Cache.get(count_cache_key, duration) do
        exact_count(timeout)
      end
    end

    def exact_count(timeout)
      Post.with_timeout(timeout) do
        posts(matrix_rooms: false).count
      end
    end

    def count_cache_key
      if is_user_dependent_search?
        "post-count-for-user:#{current_user.id.to_i}:#{self}"
      else
        "post-count:#{self}"
      end
    end
  end

  concerning :ValidationMethods do
    def validate_tag_limit!
      return if is_empty_search? || is_simple_tag?
      raise TagLimitError if tag_limit.present? && term_count > tag_limit
    end

    def validate_metatags!
      return if is_empty_search? || is_simple_tag?
      return if metatags.empty?

      order_metatags = select_metatags(*ORDER_METATAGS).map(&:to_s).map(&:downcase).uniq
      raise Error, "#{order_metatags.to_sentence} can't be used together." if order_metatags.size > 1

      SINGLETON_METATAGS.each do |name|
        metatag = select_metatags(name).first
        raise Error, "'#{name}:' can't be used more than once." if select_metatags(name).map(&:to_s).map(&:downcase).uniq.size > 1
        raise Error, "'#{metatag}' can't be negated." if metatag&.parents&.any?(&:not?)
        raise Error, "'#{metatag}' can't be used with the 'or' operator." if metatag&.parents&.any?(&:or?)
      end
    end

    # The number of unique tags, wildcards, and metatags in the search, excluding metatags that don't count against the user's tag limit.
    def term_count
      tag_names.size + wildcards.size + metatags.count { !it.name.in?(UNLIMITED_METATAGS) }
    end

    # @return [Integer] The total number of terms in the query, including free metatags.
    def total_term_count
      tag_names.size + wildcards.size + metatags.size
    end
  end

  memoize :tags, :replace_aliases, :with_implicit_metatags, :to_cnf, :aliases, :implicit_metatags, :safe_mode_metatags, :gated_metatags, :deleted_metatags, :banished_metatags, :hidden_post_metatags, :term_count, :matrix_rooms_condition
end
