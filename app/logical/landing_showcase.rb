# frozen_string_literal: true

# Picks what the landing page shows off, grouped into the categories the
# carousel's segmented control switches between.
#
# Several orderings rather than one, because a carousel of nothing but the
# newest uploads is a picture of the last hour and one of nothing but the
# highest-scoring is the same twelve images forever. The categories are named
# for what they are, so a visitor can tell which they are looking at.
#
# Everything is viewer-scoped: PostQuery applies the viewer's safe mode, the
# browsing tier and the gating rules, so anything they may not see never reaches
# the page. Slides also carry the blacklist attributes -- a showcase is the worst
# possible place to be shown something the viewer asked never to see.
class LandingShowcase
  CATEGORIES = [
    { key: "new", label: "Newest Posts", query: "order:id_desc" },
    { key: "favorites", label: "Community Favorites", query: "order:favcount" },
    { key: "creators", label: "Featured Creators", query: nil },
  ].freeze

  PER_CATEGORY = 10
  QUERY_TIMEOUT_SECONDS = 3

  attr_reader :viewer

  def initialize(viewer:)
    @viewer = viewer
  end

  # @return [Array<Hash>] one entry per category: { key:, label:, slides: [...] }.
  #   Categories with nothing to show are dropped rather than rendered empty --
  #   a segment that switches to a blank panel is worse than one that is absent.
  def categories
    @categories ||= CATEGORIES.filter_map do |category|
      posts = category_posts[category[:key]]
      next if posts.blank?

      { key: category[:key], label: category[:label], slides: posts.map { |post| slide_for(post) } }
    end
  end

  def any?
    categories.any?
  end

  private

  # Posts per category, fetched once.
  #
  # Deliberately separate from slide building. Slides need the blacklist tag
  # projection, which needs every post on the page in ONE query -- so if slide
  # building were what produced the posts, asking for the tags would re-enter
  # this method and recurse. Gather first, then render.
  def category_posts
    @category_posts ||= CATEGORIES.to_h do |category|
      posts = (category[:key] == "creators") ? featured_creator_posts : posts_for(category[:query])
      [category[:key], posts.uniq(&:id).first(PER_CATEGORY)]
    end
  end

  def posts_for(query)
    PostQuery.new(query, current_user: viewer)
      # The viewer's ORDINARY page limit, passed explicitly so paginate does not
      # read CurrentUser -- this class is handed a viewer precisely so it need
      # not touch the thread-global. Deliberately not 1: that would make page 1
      # the last allowed page, which puts paginate into a mode whose results are
      # reversed, and "Newest Posts" would render oldest-first. See
      # PostSets::Post#enforce_browsing_cap!.
      .posts_with_timeout(PER_CATEGORY * 2, includes: [:media_asset], page_limit: viewer.page_limit)
      .select { |post| showable?(post) }
  rescue StandardError => e
    # The landing page is the first thing a stranger sees, so one bad category
    # must not be the difference between a showcase and an error page. But it is
    # REPORTED, not swallowed: a blanket rescue with nothing behind it buys a
    # silent outage, not resilience.
    DanbooruLogger.log(e, query: query)
    []
  end

  # The work promoted creators chose to put forward, in their own curated order.
  def featured_creator_posts
    CreatorGallery.promoted.limit(6).flat_map do |gallery|
      gallery.creator_gallery_posts.includes(post: :media_asset).filter_map do |cgp|
        cgp.post if cgp.post && showable?(cgp.post)
      end.first(3)
    end
  rescue StandardError => e
    DanbooruLogger.log(e, category: "creators")
    []
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
    post.visible?(viewer)
  end

  def slide_for(post)
    {
      id: post.id,
      url: Rails.application.routes.url_helpers.post_path(post, preset: "modulation"),
      src: media_url(post),
      w: post.image_width,
      h: post.image_height,
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
    artist = post.tags.detect(&:artist?)
    return { name: artist.name.tr("_", " "), url: routes.posts_path(tags: artist.name, preset: "modulation") } if artist

    { name: post.uploader.name, url: routes.user_path(post.uploader_id) }
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

  def media_url(post)
    post.large_file_url
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
