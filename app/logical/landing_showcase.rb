# frozen_string_literal: true

# Picks what the landing page shows off, grouped into the categories the
# carousel's segmented control switches between.
#
# Several orderings rather than one, because a carousel of nothing but the
# newest uploads is a picture of the last hour and one of nothing but the
# highest-scoring is the same twelve images forever. The categories are named
# for what they are, so a visitor can tell which they are looking at.
#
# Everything is viewer-scoped, and #showable? IS THE GATE -- not PostQuery.
# This comment used to say PostQuery applied the viewer's safe mode, browsing
# tier and gating rules, and that is not true on this path: posts_with_timeout
# never calls with_implicit_metatags, which is also why deleted posts are
# excluded by hand below. Every rule that decides whether a viewer may see a
# post is in #showable?, and anything added to the gate elsewhere has to be
# added there too. Slides also carry the blacklist attributes -- a showcase is
# the worst possible place to be shown something the viewer asked never to see.
class LandingShowcase
  PER_CATEGORY = 10
  # How many candidates to fetch per wanted post. Wide enough that the
  # showable? filter cannot leave the row short in practice; small enough to
  # stay one bounded query.
  FETCH_WIDTH = 8

  QUERY_TIMEOUT_SECONDS = 3

  attr_reader :viewer

  def initialize(viewer:)
    @viewer = viewer
  end

  # @return [Array<Hash>] one entry per category: { key:, label:, slides: [...] }.
  #   Categories with nothing to show are dropped rather than rendered empty --
  #   a segment that switches to a blank panel is worse than one that is absent.
  def categories
    @categories ||= specs.filter_map do |spec|
      posts = category_posts[spec.key]
      next if posts.blank?

      # `visible` is how many the belt should show at once, or nil for its own
      # default -- see LandingCategory#visible_slides for what nil means.
      { key: spec.key, label: spec.label, visible: spec.visible_slides,
        slides: posts.map { |post| slide_for(post) }}
    end
  end

  delegate :any?, to: :categories

  private

  # THE CATEGORIES, FROM THE DATABASE, ONCE.
  #
  # Memoized because this is read twice per render -- here and in
  # #category_posts -- and each read used to reach LandingSetting.current for
  # a fresh SELECT. Reading four configurable rows is a query FEWER than
  # reading one configurable row twice.
  #
  # The fallback is the same bargain the "new" row's used to strike: the front
  # page staying UP matters more than it being current, and a boot that reaches
  # traffic before the migration has run must not serve a blank site. The
  # failure is logged rather than swallowed. LandingCategory::DEFAULTS is what
  # a database with no rows yields, so the fallback and the empty case are the
  # same code path.
  def specs
    @specs ||= begin
      rows = LandingCategory.visible.to_a
      rows.presence || LandingCategory::DEFAULTS.map { |d| LandingCategory.new(d) }.select(&:enabled)
    end
  rescue StandardError => e
    DanbooruLogger.log(e, context: "landing_categories")
    LandingCategory::DEFAULTS.map { |d| LandingCategory.new(d) }.select(&:enabled)
  end

  # Posts per category, fetched once.
  #
  # Deliberately separate from slide building. Slides need the blacklist tag
  # projection, which needs every post on the page in ONE query -- so if slide
  # building were what produced the posts, asking for the tags would re-enter
  # this method and recurse. Gather first, then render.
  def category_posts
    @category_posts ||= specs.to_h do |spec|
      # A creators row takes at least one per creator; see LandingCategory#wanted_posts.
      [spec.key, posts_for_spec(spec).uniq(&:id).first(spec.wanted_posts)]
    end
  end

  # Dispatch on KIND, not on a key. A key is an identifier an admin picked; the
  # kind is what the row actually is, and the four keys that exist today are
  # not the only ones that ever will.
  def posts_for_spec(spec)
    return promoted_creator_posts if spec.kind == "galleries"

    queries = spec.queries
    return [] if queries.empty?
    return posts_for(queries.first) if queries.length == 1

    # MORE THAN ONE QUERY IS NOT A REQUEST-PATH JOB. Twenty artist tags is
    # twenty searches, each with its own timeout, on the page the bare domain
    # serves to everyone -- that is not a slow page, it is an outage with a
    # spinner on it. The searches live in LandingShowcaseRefreshJob and this
    # reads what they left: a list of ids, loaded in ONE bounded query with no
    # text search in it.
    #
    # A cold cache yields an empty row, dropped the way any empty row is, and a
    # job. It fills itself in on the next render rather than making this one
    # pay for it.
    posts_by_id(LandingShowcaseCache.candidate_ids(spec))
  end

  # Load cached candidates, IN THE ORDER THE JOB CHOSE.
  #
  # `where(id: ids)` returns database order, which would throw away the
  # round-robin the job did -- the property that gives every featured creator a
  # slide before anyone gets a second. Rebuilt by index here rather than sorted
  # in SQL, because the order is a list the job produced and not a column.
  def posts_by_id(ids)
    return [] if ids.empty?

    by_id = Post.where(id: ids).includes(:media_asset, :uploader).index_by(&:id)
    ids.filter_map { |id| by_id[id] }.select { |post| showable?(post) }
  rescue StandardError => e
    DanbooruLogger.log(e, context: "landing_showcase_candidates")
    []
  end

  def posts_for(query)
    PostQuery.new(query, current_user: viewer)
             # The viewer's ORDINARY page limit, passed explicitly so paginate does not
             # read CurrentUser -- this class is handed a viewer precisely so it need
             # not touch the thread-global. Deliberately not 1: that would make page 1
             # the last allowed page, which puts paginate into a mode whose results are
             # reversed, and "Newest Posts" would render oldest-first. See
             # PostSets::Post#enforce_browsing_cap!.
             # Fetch WIDE, then filter. The row wants PER_CATEGORY posts and the
             # filter below drops anything that is not a visible image or video, so a
             # window of exactly twice the target quietly returned short rows -- the
             # front page was showing eight (operator, 2026-09-07: keep a minimum of
             # ten). A wider window is one query either way; it just stops the filter
             # eating the row.
             #
             # This is also what makes the row behave as a queue: ordered newest
             # first, a new post enters at the front and the tenth falls off the back,
             # so what is on screen only changes when something new arrives to replace
             # it. Nothing shuffles on its own.
             # :uploader as well as :media_asset -- creator_for falls back to the
             # uploader's name for any post with no artist tag, which was a second
             # query per post behind the first.
             # QUERY_TIMEOUT_SECONDS is WIRED now. It was declared and read nowhere,
             # so the timeout actually in force was current_user.statement_timeout --
             # 3s for an anonymous visitor but 9s for platinum and 60s in development,
             # which is not a cap on the front page, it is a cap on most of it.
             .posts_with_timeout(PER_CATEGORY * FETCH_WIDTH, timeout: QUERY_TIMEOUT_SECONDS * 1_000,
                                                             includes: [:media_asset, :uploader], page_limit: viewer.page_limit)
             .select { |post| showable?(post) }
  rescue StandardError => e
    # The landing page is the first thing a stranger sees, so one bad category
    # must not be the difference between a showcase and an error page. But it is
    # REPORTED, not swallowed: a blanket rescue with nothing behind it buys a
    # silent outage, not resilience.
    DanbooruLogger.log(e, query: query)
    []
  end

  # The work PROMOTED creators chose to put forward, in their own curated order.
  #
  # THE FLAG IS promoted_at, not featured_at. They are different columns for
  # different things and the names point the wrong way round: promoted_at is
  # this row, and featured_at is parked for pinning a gallery to the artist-tag
  # row later. See CreatorGallery.
  def promoted_creator_posts
    # ONE rule, on the model. This said `promoted.limit(6)` while the
    # controller excluded the current feature before limiting, so the two rows
    # could show different galleries. See CreatorGallery.landing_promoted.
    groups = CreatorGallery.landing_promoted.map do |gallery|
      gallery.creator_gallery_posts.includes(post: [:media_asset, :uploader]).filter_map do |cgp|
        cgp.post if cgp.post && showable?(cgp.post)
      end.first(3)
    end
    interleave(groups)
  rescue StandardError => e
    DanbooruLogger.log(e, category: "promoted")
    []
  end

  # ROUND-ROBIN, not concatenate.
  #
  # This took three posts from each gallery and joined them end to end, then
  # the caller cut the result to ten. Six promoted galleries therefore gave
  # 3 + 3 + 3 + 1 + 0 + 0: the last two contributed NOTHING, however good their
  # work, purely for being promoted least recently. Taking one from each in
  # turn gives every promoted creator a slide before anyone gets a second.
  def interleave(groups)
    out = []
    index = 0
    while out.length < PER_CATEGORY && groups.any? { |g| g.length > index }
      groups.each do |g|
        break if out.length >= PER_CATEGORY

        out << g[index] if g[index]
      end
      index += 1
    end
    out
  end

  # Visible to THIS viewer.
  #
  # Post#visible? already asks all three questions (safe mode, level, ban), so
  # repeating them here was redundant -- and worse than redundant: those repeats
  # were called without a viewer, which makes them fall back to the CurrentUser
  # thread-global. Outside a request that is nil, they raise, and the rescue
  # turned the exception into "nothing is showable", so the landing page came
  # back empty with no error anywhere. It failed only where CurrentUser was not
  # set, which is every context except the one it was tried in.
  def showable?(post)
    return false unless post.is_image? || post.is_video?
    # Deleted posts never belong in a showcase, whoever is looking.
    #
    # Post#visible? asks about safe mode, level and bans; it does NOT ask about
    # is_deleted. Nor does the query compensate: this class builds a PostQuery
    # and calls posts_with_timeout directly, which skips with_implicit_metatags
    # and therefore the implicit -status:deleted (the trap ArchivePulse
    # documents at length). So a deleted post was excluded only when a gated
    # tag happened to trip levelblocked? -- true for troll_jail and an
    # anonymous viewer, false for an ordinary deletion, and false for anyone
    # who can see deleted posts. The operator, at level 60, saw exactly that:
    # jail an image and it stays in the carousel for them.
    #
    # Checked against the tag as well as the flag, matching
    # ModulationPostComponent#jailed?, so a jailing whose delete half failed is
    # still kept out.
    return false if post.is_deleted?
    return false if post.has_tag?(Danbooru.config.troll_jail_tag)
    # A released post keeps its banished tag, and an admin whose reveal is
    # off is not shown one anywhere (Post#hidden_as_banished?).
    return false if post.hidden_as_banished?(viewer)

    post.visible?(viewer)
  end

  def slide_for(post)
    {
      id: post.id,
      url: Rails.application.routes.url_helpers.post_path(post),
      src: media_url(post),
      # The small variant, for every cell that is not the focused one.
      #
      # `src` is large_file_url -- an 850px sample for anything wider than
      # that. A belt cell off the focus renders at a fraction of its width and
      # shrinks further toward the edges, so fetching the sample for all of
      # them was tens of times the bytes needed to draw them, and it showed as
      # thumbnails arriving late. The focused cell still gets the sample.
      thumb: thumb_url(post),
      w: post.image_width,
      h: post.image_height,
      # Videos are real posts and belong in the showcase, but they are not
      # <img> content -- rendering one as an image is a guaranteed broken frame
      # regardless of whether the viewer may load it.
      kind: media_kind(post),
      creator: creator_for(post),
      platform: platform_for(post),
      # Same contract as the gallery cards; see FourierTagSource.blacklist_tags_for
      # for why the tags are the gated projection and not the tag string.
      tags: blacklist_tags[post].to_a.join(" "),
      rating: post.rating,
      flags: post.status_flags,
      score: post.score,
      uploader_id: post.uploader_id,
    }
  end

  # Who made it. The artist tag is what this site calls a Creator, so it is the
  # answer when there is one; the uploader is the fallback, because "created by
  # nobody" is not a sentence worth rendering.
  def creator_for(post)
    artist = post.tag_array.find { |name| artist_names.include?(name) }
    return { name: artist.tr("_", " "), url: routes.posts_path(tags: artist) } if artist

    { name: post.uploader.name, url: routes.user_path(post.uploader_id) }
  end

  # WHICH TAG NAMES ON THIS PAGE ARE ARTISTS, IN ONE QUERY FOR THE WHOLE PAGE.
  #
  # creator_for used to ask `post.tags`, which is `Tag.where(name: tag_array)`
  # (post.rb:353-355) -- a fresh round trip PER POST, up to forty of them on
  # the page the bare domain serves to everyone. That is the shape of query
  # load this site has already been hurt by: the booru exhausted Postgres
  # max_connections once, and the media gate's unindexed scans through a small
  # pool once left every thumbnail sitting for four seconds.
  #
  # One IN query over the union of every tag name on the page, returning names
  # only. Memoized beside blacklist_tags, which gathers over the same set for
  # the same reason.
  #
  # IT ALSO MAKES THE ANSWER DETERMINISTIC, which the old one was not: a post
  # with two artist tags got whichever `Tag.where` happened to return first,
  # and that is database order, not tag order. This takes the first in the
  # post's own tag_array, so the same post names the same creator every time.
  def artist_names
    @artist_names ||= begin
      names = all_posts.flat_map(&:tag_array).uniq
      names.empty? ? Set.new : Tag.where(name: names, category: Tag.categories.artist).pluck(:name).to_set
    end
  end

  # Where it was posted. `key` is a stable slug so a per-platform logo can be
  # hung off it later without the name (which is display text, and may be
  # retitled) becoming an identifier.
  def platform_for(post)
    source = post.source.to_s
    return nil if source.blank?
    # Matrix media is addressed by mxc:// URI, which no generic URL parser names.
    return { name: "Matrix", key: "matrix" } if source.start_with?("mxc://")

    name = Source::URL.site_name(source)
    name = Addressable::URI.parse(source).host if name.blank?
    return nil if name.blank?

    { name: name.to_s, key: name.to_s.parameterize }
  rescue StandardError
    nil
  end

  def media_kind(post)
    return "video" if post.is_video?
    return "image" if post.is_image?

    "other"
  end

  def media_url(post)
    post.large_file_url
  rescue StandardError
    nil
  end

  # nil when there is no small variant to have -- the caller falls back to src,
  # which is what a post with no variants had to use anyway.
  def thumb_url(post)
    return nil unless post.media_asset.has_variant?(:"360x360")

    post.media_asset.variant(:"360x360").file_url
  rescue StandardError
    nil
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for(all_posts, viewer)
  end

  def all_posts
    @all_posts ||= category_posts.values.flatten.uniq(&:id)
  end

  def routes
    Rails.application.routes.url_helpers
  end
end
