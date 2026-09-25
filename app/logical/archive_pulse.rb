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

  # The pace of uploads, for "when is the next one". Nothing schedules the next
  # upload: sampling's poster runs a pass, sleeps two minutes once it has
  # drained, and posts whatever the taggers have cleared by then -- measured
  # 2026-09-25, a pass every 173-210s posting 2-15 -- and the tunnel posts when
  # someone posts in Matrix. So the next one is read off the rhythm of the last
  # few. Posts closer together than BURST_GAP are one pass; the pace is the
  # median gap between pass STARTS over the last CADENCE_PASSES of them.
  BURST_GAP = 60.seconds
  CADENCE_WINDOW = 2.hours
  CADENCE_SAMPLE = 300
  CADENCE_PASSES = 10
  CADENCE_MIN_GAPS = 4

  # A pass lasts seconds and comes round in minutes; a two-minute cache would
  # be most of a cycle stale by the time it was read.
  CADENCE_TTL = 30.seconds

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

  # @return [Hash, nil] {last_at:, burst_at:, every:} -- the newest upload, when
  #   the pass it belongs to began, and the usual seconds between passes -- or
  #   nil when there are too few recent passes to call it a pace. Read over the
  #   posts this viewer can reach: the pace of the gated set says as much about
  #   its volume as a count would.
  def cadence
    @cadence ||= cached("cadence", CADENCE_TTL) do
      times = Post.with_timeout(QUERY_TIMEOUT_MS) do
        post_query.posts.where(created_at: CADENCE_WINDOW.ago..).reorder(created_at: :desc).limit(CADENCE_SAMPLE).pluck(:created_at)
      end
      starts = times.reverse.chunk_while { |a, b| b - a < BURST_GAP }.map(&:first)
      gaps = starts.each_cons(2).map { |a, b| (b - a).round }.last(CADENCE_PASSES)
      { last_at: times.first, burst_at: starts.last, every: gaps.sort[gaps.size / 2] } if gaps.size >= CADENCE_MIN_GAPS
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
  def cached(name, ttl = CACHE_TTL, &)
    # The reveal toggle too: two admins at one level see different archives
    # when one of them has it off (TagBanishment.withholds_posts_from?).
    Cache.get("archive-pulse/#{name}/#{viewer.level}/#{TagBanishment.withholds_posts_from?(viewer) ? "withheld" : "all"}", ttl, race_condition_ttl: [ttl, 30.seconds].min, &)
  rescue ActiveRecord::QueryCanceled, ActiveRecord::StatementInvalid
    # A stat that timed out is omitted, not zero. Reporting zero posts because a
    # count was slow would tell the visitor the opposite of the truth.
    nil
  end
end
