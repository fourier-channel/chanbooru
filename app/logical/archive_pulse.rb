# frozen_string_literal: true

# The archive's vital signs, for a visitor who cannot see the pictures.
#
# 41chan is closed, and the pictures behind the gate stay behind it. That leaves
# a stranger with no way to tell a live, filling archive from an empty shell
# with a nice stylesheet -- and those two things should not look the same. These
# are the numbers that distinguish them: how much is in here, how many tags it
# has been sorted under, and how long ago the last one arrived.
#
# Everything is viewer-scoped. A count taken over posts the viewer may not see
# would report the size of the gated set to exactly the people the gate exists
# to keep it from -- not the images, but the volume, and volume is information.
# So the numbers a stranger sees are the numbers of the archive as it exists FOR
# them, which is also the honest thing to show: this is what is waiting.
class ArchivePulse
  # Long enough that a page load never pays for these, short enough that "four
  # minutes ago" is not a lie by the time it is read. The freshness of the
  # newest-upload stamp is the whole point of showing it.
  CACHE_TTL = 2.minutes

  # These run for anonymous visitors on the site's front page, which is the
  # request most likely to arrive in a crowd. A stat that cannot be computed
  # quickly is dropped from the strip rather than allowed to hold the page.
  QUERY_TIMEOUT_MS = 2_000

  attr_reader :viewer

  # A nil viewer resolves to anonymous rather than raising. Same rule as the
  # gating: the unknown-viewer case has to fall towards showing less, and
  # anonymous is the smallest view of the archive there is.
  def initialize(viewer:)
    @viewer = viewer || User.anonymous
  end

  # @return [Integer, nil] posts this viewer could reach, or nil if not countable
  def posts
    @posts ||= cached("posts") { post_query.fast_count(timeout: QUERY_TIMEOUT_MS) }
  end

  # Whether there is anything at all to print. Any one stat surviving is enough:
  # a strip reading "48 tags -- last upload 4 minutes ago" still makes the point
  # if the post count happened to time out.
  def any?
    posts.to_i.positive? || tags.to_i.positive? || newest_at.present?
  end

  # Tags that are actually on something. The full tags table includes every name
  # ever typed and then removed, which would overstate the archive by counting
  # its own history.
  def tags
    @tags ||= cached("tags") { Tag.visible_to(viewer).where(post_count: 1..).count }
  end

  # @return [ActiveSupport::TimeWithZone, nil] when the most recent reachable
  #   post arrived.
  def newest_at
    @newest_at ||= cached("newest_at") do
      Post.with_timeout(QUERY_TIMEOUT_MS) { post_query.posts.maximum(:created_at) }
    end
  end

  private

  # An empty search, narrowed by the viewer's safe mode and the gating rules.
  #
  # with_implicit_metatags is load-bearing and easy to leave off, because
  # PostQuery.normalize alone LOOKS like it has already applied them -- the
  # viewer is right there in the constructor. It has not. Without this the
  # counts come back over the whole posts table: the strip told a stranger how
  # many gated posts exist, which is not the pictures but is still the one
  # number the gate is meant to withhold. The listing pages escape this only
  # because PostQuery.search calls it for them.
  def post_query
    @post_query ||= PostQuery.normalize("", current_user: viewer).with_implicit_metatags
  end

  # Keyed by viewer level rather than by user: the numbers differ between a
  # stranger and a member because the gating does, but they do not differ
  # between two strangers, and a per-user key would make this cache useless for
  # the audience it exists for.
  def cached(name, &)
    Cache.get("archive-pulse/#{name}/#{viewer.level}", CACHE_TTL, race_condition_ttl: 30.seconds, &)
  rescue ActiveRecord::QueryCanceled, ActiveRecord::StatementInvalid
    # A stat that timed out is omitted, not zero. Reporting zero posts because a
    # count was slow would tell the visitor the opposite of the truth.
    nil
  end
end
