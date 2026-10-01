# frozen_string_literal: true

# The blog's posts for the landing carousel's Blog row, read in the background
# from the blog's own index and served to the request from the cache.
#
# THE BLOG IS NOT THE BOORU'S. It is written in fourier-domain (posts/*.md),
# rendered by its tools/render-docs.py and served from 41chan.net as static
# files -- among them blog/index.json, which that script calls "what a client
# fetches to list the posts". This row is one more reader of that file. What
# is kept here is a cache of the index's own fields, and every link and
# picture points back at the blog: the booru holds no copy of a blog image
# (every image exists once, operator ruling 2026-09-30).
#
# OFF THE REQUEST, for the reason LandingShowcaseCache gives: the page the
# bare domain serves to everyone must not wait on another host. The read runs
# in LandingBlogRefreshJob on the same clock as the creator rows, and a visit
# that finds the cache cold or stale is served what is there and queues one.
#
# A SIBLING OF LandingShowcaseCache, NOT PART OF IT. That class caches post ids
# precisely because an id carries nothing a viewer could be wrongly shown;
# this caches display text and links, so it cannot make that claim, and it
# keeps state the ids never needed -- the outcome of the last attempt, for the
# console. The timing constants are that class's, by reference, so the two
# halves of the carousel cannot run on different clocks.
#
# A FAILED READ NEVER REPLACES A GOOD ONE. The posts are written only by a
# read that succeeded; every attempt, good or bad, writes the status the
# landing console shows, with the remedy in the error text. So an outage of
# the blog keeps the row as it was for TTL, and says so where an admin looks.
class LandingBlogCache
  # Bump to invalidate every cached read at once.
  VERSION = 1

  TTL = LandingShowcaseCache::TTL
  STALE_AFTER = LandingShowcaseCache::STALE_AFTER
  ENQUEUE_DEBOUNCE = LandingShowcaseCache::ENQUEUE_DEBOUNCE
  # The status outlives the posts, so the console can still say what went
  # wrong after a long outage has emptied the row.
  STATUS_TTL = 7.days

  FETCH_TIMEOUT_SECONDS = 10
  # The index is a few hundred bytes per post. Anything this size is not it.
  MAX_BYTES = 1.megabyte
  # The most posts kept; the row shows LandingShowcase::PER_CATEGORY of them.
  MAX_POSTS = 50

  # Caps on what reaches the page, which carries every slide in one attribute.
  MAX_TITLE = 200
  MAX_AUTHOR = 80
  MAX_BLURB = 300
  MAX_ALT = 200

  # A slug becomes part of a slide id and a CSS selector on the page, so it
  # is held to the characters render-docs.py's filenames actually use.
  SLUG = /\A[a-z0-9][a-z0-9-]{0,99}\z/
  DATE = /\A\d{4}-\d{2}-\d{2}\z/

  class Error < StandardError; end

  class << self
    def index_url
      Danbooru.config.landing_blog_index_url
    end

    # The posts to show, in the blog's own order -- and a queued read when
    # there are none yet or they are older than STALE_AFTER. NEVER FETCHES.
    def posts
      entry = Rails.cache.read(cache_key)
      enqueue_refresh if entry.nil? || stale?(entry)
      entry ? Array(entry[:posts]) : []
    end

    # The job's work: read the index and keep what a slide needs.
    #
    # @return [Integer] how many posts were kept
    # @raise [Error] when the index cannot be read or holds nothing showable,
    #   after recording the failure for the console
    def refresh!(now: Time.zone.now)
      problems = []
      rows = fetch
      posts = rows.each_with_index.filter_map { |row, index| project(row, index, problems) }.first(MAX_POSTS)
      # NOT rows.any?, which tests truthiness: an index of nothing but nulls
      # would read as an empty blog instead of an unusable one.
      if !rows.empty? && posts.empty?
        raise Error, "none of the #{rows.length} posts in #{index_url} could be shown (#{problems.first(3).join("; ")}) -- " \
                     "fix those rows; fourier-domain's tools/render-docs.py writes them"
      end

      Cache.put(cache_key, { posts: posts, at: now.to_i }, TTL)
      write_status(now, ok: true, listed: rows.length, count: posts.length, problems: problems)
      posts.length
    rescue StandardError => e
      write_status(now, ok: false, error: e.is_a?(Error) ? e.message : "#{e.class}: #{e.message}", problems: problems)
      raise
    end

    # The outcome of the last attempt, for the landing console, or nil if no
    # attempt has been recorded: { at:, ok:, url:, listed:, count:, problems:, error: }.
    def status
      Rails.cache.read(status_key)
    end

    # Keyed by the ADDRESS, so pointing the row at another index never serves
    # the old one's posts.
    def cache_key
      "landing_blog:v#{VERSION}:#{Cache.hash(index_url)}"
    end

    def status_key
      "#{cache_key}:status"
    end

    def stale?(entry)
      Time.zone.now.to_i - entry[:at].to_i > STALE_AFTER.to_i
    end

    private

    # One job per window however many visitors find the cache cold. Not a
    # lock -- see LandingShowcaseCache#enqueue_refresh for why that is enough.
    def enqueue_refresh
      Cache.get("#{cache_key}:enqueued", ENQUEUE_DEBOUNCE) do
        LandingBlogRefreshJob.perform_later
        Time.zone.now.to_i
      end
    end

    def write_status(now, ok:, problems:, listed: nil, count: nil, error: nil)
      Cache.put(status_key, { at: now.to_i, ok: ok, url: index_url, listed: listed, count: count,
                              problems: problems, error: error }, STATUS_TTL)
    end

    # The index, as a list of rows.
    #
    # `internal`, not `external`: the address is configuration, never user
    # input, and a dev stack points it at a private address that `external`
    # refuses. Redirects are NOT followed -- an index that has moved is a
    # configuration to correct, said in the error, not a hop taken silently.
    #
    # JSON.parse, not response.parse: the client's JSON adapter turns a body
    # it cannot parse into {}, which would read as a blog with no posts.
    def fetch
      response = Danbooru::Http.internal.timeout(FETCH_TIMEOUT_SECONDS).no_follow
                               .headers(Accept: "application/json").get(index_url)
      raise Error, failure(response) unless response.code == 200

      body = response.body.to_s
      if body.bytesize > MAX_BYTES
        raise Error, "#{index_url} is #{body.bytesize} bytes, far more than a blog index -- check that the address is the blog's index.json"
      end

      data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
      unless data.is_a?(Array)
        raise Error, "#{index_url} is JSON but not a list of posts -- point landing_blog_index_url at the blog's index.json"
      end

      data
    rescue JSON::ParserError => e
      raise Error, "#{index_url} answered with something that is not valid JSON (#{e.message.truncate(60)}) -- check that the address " \
                   "is the blog's index.json, which fourier-domain's tools/render-docs.py writes"
    end

    # What went wrong, and what to do about it. The 59x codes are the HTTP
    # client's own stand-ins for a request that never got an answer.
    def failure(response)
      host = Addressable::URI.parse(index_url).host
      case response.code
      when 597
        "reading #{index_url} timed out after #{FETCH_TIMEOUT_SECONDS}s -- check that the jobs container can reach #{host}"
      when 598
        "could not connect to #{host} -- check the address in landing_blog_index_url, and that the jobs container can resolve and reach it"
      when 590
        "the TLS handshake with #{host} failed -- check the certificate served there"
      when 590..599
        "the request to #{index_url} failed before any answer (client code #{response.code}) -- check that the jobs container can reach #{host}"
      when 300..399
        "#{index_url} redirects to #{response.headers["Location"].presence || "an unnamed address"} -- set landing_blog_index_url " \
        "to where the index lives now"
      else
        if response.code.in?([403, 503]) && response.mime_type == "text/html"
          challenge = "#{index_url} answered #{response.code} with an HTML page, most likely a Cloudflare challenge"
          "#{challenge} -- let the booru's requests through in Cloudflare, or set landing_blog_index_url to an address that is not challenged"
        else
          "#{index_url} answered HTTP #{response.code} -- check that the blog is deployed and serves its index.json there"
        end
      end
    end

    # One post as a slide needs it, or nil (with the reason in `problems`).
    def project(row, index, problems)
      unless row.is_a?(Hash)
        problems << "entry #{index + 1} is not an object"
        return nil
      end

      slug = row["slug"]
      unless slug.is_a?(String) && slug.match?(SLUG)
        problems << "entry #{index + 1}: its slug #{slug.to_s.truncate(40).inspect} is not lowercase letters, digits and dashes"
        return nil
      end

      title = text(row["title"], MAX_TITLE)
      if title.blank?
        problems << "#{slug}: it has no title"
        return nil
      end

      url = on_blog(row["html"])
      if url.nil?
        problems << "#{slug}: its page link #{row["html"].to_s.truncate(80).inspect} is not on the blog's own origin"
        return nil
      end

      image = picture(row["image"], slug, problems)
      {
        slug: slug,
        title: title,
        url: url,
        author: text(row["author"], MAX_AUTHOR).presence,
        blurb: text(row["lead"], MAX_BLURB).presence,
        date: (row["date"] if row["date"].is_a?(String) && row["date"].match?(DATE)),
        image: image&.dig(:src),
        image_alt: image&.dig(:alt),
      }
    end

    # The post's picture, {src, alt}, or nil. A picture the row cannot use
    # costs the post its picture, not its place.
    def picture(value, slug, problems)
      return nil if value.nil?

      unless value.is_a?(Hash) && value["src"].is_a?(String)
        problems << "#{slug}: its image is not {src, alt}; shown without a picture"
        return nil
      end

      src = on_blog(value["src"])
      if src.nil?
        problems << "#{slug}: its picture #{value["src"].truncate(80).inspect} is not on the blog's own origin; shown without it"
        return nil
      end

      { src: src, alt: text(value["alt"], MAX_ALT) }
    end

    # A link from the index, made absolute against the index's own address,
    # and refused unless it stays on that origin -- the index names the blog's
    # pages and pictures, and a link anywhere else (or a javascript: one) is
    # not something this row will put on the front page.
    def on_blog(path)
      return nil unless path.is_a?(String) && path.present?

      base = Addressable::URI.parse(index_url).normalize
      uri = base.join(path).normalize
      return nil unless uri.scheme.in?(%w[http https]) && uri.origin == base.origin

      uri.to_s
    rescue Addressable::URI::InvalidURIError
      nil
    end

    def text(value, max)
      value.is_a?(String) ? value.squish.truncate(max) : ""
    end
  end
end
