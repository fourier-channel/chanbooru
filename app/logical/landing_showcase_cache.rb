# frozen_string_literal: true

# The candidate posts for a carousel category that needs MORE THAN ONE SEARCH,
# computed in the background and read from the cache by the request.
#
# THE PROBLEM THIS EXISTS FOR, in the operator's words (2026-09-17): "Assume
# that ~20 creators will be in the 'Featured' list. How do you best accommodate
# this without bogging the server down with repeat searches every other second?"
#
# Twenty featured artists is twenty searches, because an anonymous visitor may
# search only TWO TAGS and the landing page runs as whoever is looking at it --
# so LandingCategory#queries returns one query per tag and never one query of
# all of them. Twenty searches at a 3 second timeout each is up to a minute, on
# the page the bare domain serves to everyone. That is not a slow page, it is an
# outage with a spinner.
#
# So the searches move off the request entirely:
#
#   * LandingShowcaseRefreshJob runs them, one per tag, and stores the POST IDS.
#   * The request reads that list and loads those posts by id -- ONE query,
#     bounded, no text search, no timeout risk.
#   * Every viewer still filters the result through LandingShowcase#showable?,
#     so the shared list can never show anyone something they may not see.
#
# WHAT IS CACHED IS IDS, NOT SLIDES, and that is the whole reason this is safe
# to share between viewers. A slide carries a media URL and the viewer's own
# blacklist projection; an id carries nothing. The gate stays where it already
# is, per viewer, on every render.
#
# SINGLE-QUERY CATEGORIES DO NOT COME THROUGH HERE. "Fresh from DEGEN" is one
# bounded search with a 3 second cap and it is meant to be live -- the row is a
# queue, and a new capture appearing at the front within the minute is the
# point of it. Putting it behind a fifteen-minute refresh would buy nothing and
# cost exactly the thing it is for.
class LandingShowcaseCache
  # Bump to invalidate every cached row at once, without knowing their keys.
  VERSION = 1

  # How long an entry is still SERVED. Long on purpose: a stale row is better
  # than an absent one, and the refresh below happens long before this.
  TTL = 24.hours
  # When the read path asks for a refresh. Stale-while-revalidate: the visitor
  # who notices the staleness is served the old list immediately and never
  # waits for the new one.
  STALE_AFTER = 15.minutes
  # One enqueue per category per window, however many requests arrive in it.
  ENQUEUE_DEBOUNCE = 2.minutes

  # Posts kept per tag. Small, because the row shows PER_CATEGORY (10) in total
  # and every creator should get a slide before anyone gets a second -- see
  # #interleave. Wide enough that showable? dropping a post does not empty that
  # creator's contribution.
  PER_TAG = 4
  # A ceiling on the stored list whatever the tag count, so a misconfigured
  # thirty-tag category cannot put an unbounded array in the cache.
  MAX_CANDIDATES = 120

  # Longer than the request path's 3s, because this is a background job where
  # 30 x 3s is fine and an outage in a request.
  QUERY_TIMEOUT_SECONDS = 3

  class << self
    # The ids to render, and an enqueue if they are missing or old.
    #
    # NEVER RUNS A SEARCH. A cache miss yields an empty row -- dropped by the
    # showcase the same way any empty row is -- and a job. The alternative,
    # computing it here on a miss, is the outage above with a rare trigger
    # instead of a constant one, which is worse than the constant kind because
    # it only happens when the cache is cold and everyone is arriving.
    def candidate_ids(spec)
      entry = read(spec)
      enqueue_refresh(spec) if entry.nil? || stale?(entry)
      entry ? Array(entry[:ids]) : []
    end

    # The job's work: run the queries and store what they found.
    #
    # @return [Integer] how many ids were stored, for the job to log.
    def refresh!(spec, now: Time.zone.now)
      ids = gather_ids(spec)
      write(spec, ids, now)
      ids.length
    end

    # Keyed by the QUERIES, not just the category, so editing the tag list
    # invalidates the old list instead of serving it. An admin who removes a
    # creator must not keep seeing that creator's work while the cache expires.
    def cache_key(spec)
      "landing_showcase:v#{VERSION}:#{spec.key}:#{Cache.hash(spec.queries.join("\n"))}"
    end

    def read(spec)
      Rails.cache.read(cache_key(spec))
    end

    def write(spec, ids, now = Time.zone.now)
      Cache.put(cache_key(spec), { ids: ids, at: now.to_i }, TTL)
    end

    def stale?(entry)
      Time.zone.now.to_i - entry[:at].to_i > STALE_AFTER.to_i
    end

    private

    # One job per category per window. Not a lock -- Rails.cache#fetch is not
    # atomic across processes, so a burst spanning the write can still produce
    # two jobs. Two is not a stampede; twenty is, and this is what stops twenty.
    # Said plainly rather than described as a mutex it is not.
    def enqueue_refresh(spec)
      Cache.get("#{cache_key(spec)}:enqueued", ENQUEUE_DEBOUNCE) do
        LandingShowcaseRefreshJob.perform_later(spec.key)
        Time.zone.now.to_i
      end
    end

    # ONE SEARCH PER TAG, interleaved.
    #
    # AS ANONYMOUS, deliberately. The list is shared between every viewer, so it
    # has to be built for the narrowest of them -- what a stranger could see.
    # The consequence is real and worth stating: a post only a high-level user
    # may see will not appear in this row even for that user. That is the right
    # trade for a landing carousel, whose whole job is to show a stranger what
    # the site has, and it means the shared list can never be a way to learn
    # that a restricted post exists.
    def gather_ids(spec)
      viewer = User.anonymous
      groups = spec.queries.map { |query| ids_for(query, viewer) }
      interleave(groups).first(MAX_CANDIDATES)
    end

    def ids_for(query, viewer)
      PostQuery.new(query, current_user: viewer)
               .posts_with_timeout(PER_TAG, timeout: QUERY_TIMEOUT_SECONDS * 1_000,
                                            page_limit: viewer.page_limit)
               .map(&:id)
    rescue StandardError => e
      # One bad tag must not cost the other nineteen. Reported, never swallowed:
      # a row quietly short by one creator is the failure this whole class is
      # written against.
      DanbooruLogger.log(e, context: "landing_showcase_cache", query: query)
      []
    end

    # ROUND-ROBIN, the same rule LandingShowcase#interleave applies to promoted
    # galleries and for the same reason. Concatenating twenty groups of four and
    # cutting to ten gives the first three creators every slide and the other
    # seventeen none, purely for their position in a list. One each, then a
    # second each.
    def interleave(groups)
      out = []
      index = 0
      while groups.any? { |g| g.length > index }
        groups.each { |g| out << g[index] if g[index] }
        index += 1
      end
      out.uniq
    end
  end
end
