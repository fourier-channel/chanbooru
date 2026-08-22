# frozen_string_literal: true

# Picks the posts the landing page shows off.
#
# Drawn from several orderings rather than one, because a slideshow of nothing
# but the newest uploads is a picture of the last hour and a slideshow of nothing
# but the highest-scoring is the same twelve images forever. Mixing them and
# shuffling gives a stranger a fair impression of the place, and gives a returning
# visitor something different to look at.
#
# Everything here is viewer-scoped: PostQuery applies the viewer's safe mode and
# visibility, and anything they may not see is dropped before it reaches the page.
# The slides also carry the blacklist attributes, so a viewer's own rules apply
# here exactly as they do in the gallery -- a showcase is the worst possible place
# to be shown something you have asked never to see.
class LandingShowcase
  # Each pool contributes at most POOL_DEPTH posts to the shuffle.
  POOLS = {
    "new" => "order:id_desc",
    "loved" => "order:favcount",
    "top" => "order:score",
  }.freeze

  POOL_DEPTH = 12
  SLIDE_COUNT = 18
  QUERY_TIMEOUT_SECONDS = 3

  attr_reader :viewer

  def initialize(viewer:)
    @viewer = viewer
  end

  # @return [Array<Hash>] slides, shuffled, ready to serialise.
  def slides
    picked = {}

    pools.each do |label, posts|
      posts.each do |post|
        # First pool to claim a post keeps it, so a post that is both new and
        # popular appears once rather than twice.
        picked[post.id] ||= { post: post, label: label }
      end
    end

    picked.values.shuffle.first(SLIDE_COUNT).map { |entry| slide_for(entry[:post], entry[:label]) }
  end

  private

  # Run once per instance. Memoised because the blacklist lookup needs the same
  # posts the slides were built from -- and because these are ordered queries, a
  # second call would not merely cost another round trip, it could return
  # different posts and leave slides whose tags were never fetched.
  def pools
    @pools ||= POOLS.transform_values { |query| posts_for(query) }
  end

  def posts_for(query)
    PostQuery.new(query, current_user: viewer)
      # page_limit passed explicitly because paginate otherwise defaults it to
      # CurrentUser.user.page_limit -- a thread-global this class is given a
      # viewer precisely so it does not have to read. The showcase only ever
      # wants the first page of each pool.
      .posts_with_timeout(POOL_DEPTH, includes: [:media_asset], page_limit: 1)
      .select { |post| showable?(post) }
  rescue StandardError => e
    # The landing page is the first thing a stranger sees, so one bad pool must
    # not be the difference between a showcase and an error page. But it is
    # REPORTED, not swallowed: an earlier version of this rescue turned a typo
    # into a silently empty landing page that looked like "no posts yet", and a
    # blanket rescue with nothing behind it buys exactly that.
    DanbooruLogger.log(e, query: query)
    []
  end

  # Visible AND actually renderable: a post whose file the viewer may not load
  # would be an empty frame in a slideshow with no explanation.
  def showable?(post)
    post.visible?(viewer) && !post.levelblocked? && !post.banblocked? && !post.safeblocked?
  rescue StandardError
    false
  end

  def slide_for(post, label)
    {
      id: post.id,
      label: label,
      url: Rails.application.routes.url_helpers.post_path(post, preset: "modulation"),
      src: media_url(post),
      w: post.image_width,
      h: post.image_height,
      # Same contract as the gallery cards; see FourierTagSource.blacklist_tags_for
      # for why the tags are the gated projection and not the tag string.
      tags: blacklist_tags[post].to_a.join(" "),
      rating: post.rating,
      flags: post.status_flags,
      score: post.score,
      uploader_id: post.uploader_id,
    }
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
    @all_posts ||= pools.values.flatten.uniq(&:id)
  end
end
