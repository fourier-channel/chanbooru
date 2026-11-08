# frozen_string_literal: true

# TIMED LINKS (fourier-basis docs/design/CREATOR_REACH.md sec 2; operator
# 2026-11-08, "Sampling, snapshot"): an address a creator makes for up to 24
# of their own posts, at any rating, that stops answering after a day they
# pick -- they send it out for October, and in November it is gone with
# nothing to clean up.
#
# Sampling's publications service holds the link, its end, End now, both
# settings (the longest life, the most live links per creator) and the image
# grant, and serves the page. The booru asks it over the box's own network
# through Caddy's :5181 door -- the one fourier-auth reads published pages
# through -- with a key only the booru holds, and sends the post list ONCE,
# when the link is made. Sampling never asks the booru again: on every view
# it withholds jailed, banished and flagged posts by its own lists. The trade
# the operator accepted: a post the booru hides later for any other reason
# stays on a live link until the link ends or the creator presses End now.
#
# The OWNER sampling counts links against is the gallery, by id: one creator,
# one page, and it does not change when the page is linked to another account.
#
# FAIL LOUDLY (memory fail-loudly-no-fallbacks): unset config, a refused key,
# a timeout, or an answer of the wrong shape is a Failure naming the fix.
# Nothing is cached and nothing falls back. What the creator got wrong, or a
# limit they reached, is a Refused, in words for them.
class CreatorTimedLinks
  # Something between the booru and sampling is wrong: the site owner fixes it.
  class Failure < StandardError; end
  # The creator's choice cannot be made: the words are for them.
  class Refused < StandardError; end

  # One live link, as sampling lists it.
  Link = Struct.new(:hash_id, :url, :title, :created_at, :ends_at, :post_count, keyword_init: true)
  # The creator's live links and the two settings sampling holds.
  Listing = Struct.new(:links, :max_live, :max_days, keyword_init: true)

  TIMEOUT = 5
  MAX_POSTS = 24
  # What the media gate serves, as sampling's CREATOR_EXTS lists it.
  EXTS = %w[jpg jpeg png gif webp webm mp4].freeze
  KEY_HEADER = "X-Fourier-Creator-Key"
  TITLE_MAX = 120

  NOT_SET = "Timed links are not switched on: set DANBOORU_FOURIER_SAMPLING_INTERNAL_URL and DANBOORU_FOURIER_SAMPLING_CREATOR_KEY " \
            "in the booru's .env.local (the key is the same value as FS_CREATOR_LINK_KEY in /etc/fourier-sampling/env), then recreate the booru."

  attr_reader :gallery

  def initialize(gallery, url: Danbooru.config.fourier_sampling_internal_url, key: Danbooru.config.fourier_sampling_creator_key, http: Danbooru::Http.internal)
    @gallery = gallery
    @base = url.to_s.chomp("/")
    @key = key.to_s
    @http = http
  end

  # Whether the booru is configured to ask at all.
  def configured?
    @base.present? && @key.present?
  end

  # @return [Listing] the gallery's live links, newest first
  def list
    data = ask(:get, "/api/publications", params: { owner: gallery.id })
    links = data["links"]
    raise Failure, "#{where("/api/publications")} answered links that are not a list -- check that fourier-sampling is new enough to serve creator links" unless links.is_a?(Array)

    max_live = data["max_live"]
    max_days = data["max_days"]
    unless max_live.is_a?(Integer) && max_live.positive? && max_days.is_a?(Numeric) && max_days.positive?
      raise Failure, "#{where("/api/publications")} answered no max_live or max_days -- check FS_CREATOR_LINK_MAX_LIVE and FS_CREATOR_LINK_MAX_DAYS in /etc/fourier-sampling/env"
    end

    Listing.new(links: links.map { |row| link(row) }.sort_by { |l| -l.created_at.to_f }, max_live: max_live, max_days: max_days)
  end

  # The last day a link made now may run to: the link ends at the END of the
  # day picked, and that must fall within max_days of now.
  def self.latest_end_date(max_days, now: Time.zone.now)
    limit = now + max_days.to_f.days
    day = limit.to_date
    day -= 1 if day.in_time_zone.end_of_day > limit
    day
  end

  # Make a link. Checks the posts here, in the creator's words, and lets
  # sampling decide the limit on live links (it counts under its own lock).
  #
  # @param posts [Array<Post>] the creator's posts, in the order to show them
  # @param ends_on [Date] the last day the link answers
  # @param max_days [Numeric] the longest life, as sampling listed it
  # @return [Link]
  def create(posts:, title:, ends_on:, max_days:, now: Time.zone.now)
    raise Refused, "Pick at least one post." if posts.empty?
    raise Refused, "A timed link shows at most #{MAX_POSTS} posts; you picked #{posts.size}. Take some off." if posts.size > MAX_POSTS

    latest = self.class.latest_end_date(max_days, now: now)
    raise Refused, "Pick an end date from today on." if ends_on < now.to_date
    raise Refused, "Pick an end date on or before #{latest.iso8601}: a timed link lives at most #{max_days.to_i} days." if ends_on > latest

    posts.each do |post|
      raise Refused, "Post ##{post.id} is deleted, and a timed link cannot show it." if post.is_deleted?
      raise Refused, "Post ##{post.id} is a .#{post.file_ext} file, and a timed link shows pictures and videos only (#{EXTS.join(", ")})." unless post.file_ext.in?(EXTS)
    end

    body = {
      kind: "creator",
      owner: gallery.id.to_s,
      owner_name: (gallery.title.presence || gallery.slug).to_s,
      title: title.to_s.squish.first(TITLE_MAX),
      expires_seconds: (ends_on.in_time_zone.end_of_day - now).ceil,
      posts: posts.map { |post| { id: post.id, md5: post.md5, ext: post.file_ext, w: post.image_width.to_i, h: post.image_height.to_i, rating: post.rating } },
    }
    data = ask(:post, "/api/publish", json: body)
    link(data["link"])
  end

  # End a live link now. A link already gone is the creator's to hear about.
  # @return [String] the hash ended
  def finish(hash_id)
    raise Refused, "That is not one of your links." unless hash_id.to_s.match?(/\A[0-9a-f]{32}\z/)

    ask(:delete, "/api/publish", json: { hash: hash_id.to_s, owner: gallery.id.to_s })
    hash_id.to_s
  end

  private

  def where(path) = "fourier-sampling #{path}"

  # One request; the parsed object on 200, else Refused (the creator's limit,
  # a link already ended) or Failure (everything else, with its fix).
  def ask(method, path, **options)
    raise Failure, NOT_SET unless configured?

    response = @http.timeout(TIMEOUT).no_follow.headers(KEY_HEADER => @key, Accept: "application/json").send(method, "#{@base}#{path}", **options)
    data = parse(path, response)
    return data if response.code == 200

    said = data["error"].to_s
    case response.code
    when 409 then raise Refused, said.presence || "You already have as many live links as allowed. End one with End now, or wait for one to run out."
    when 404 then raise Refused, "That link has already ended, or is not one of yours."
    when 401 then raise Failure, "#{where(path)} refused the booru's key -- DANBOORU_FOURIER_SAMPLING_CREATOR_KEY and sampling's FS_CREATOR_LINK_KEY must hold the same value"
    when 403 then raise Failure, "#{where(path)} answered 403 -- the request did not come through Caddy's :5181 door with the creator key; check DANBOORU_FOURIER_SAMPLING_INTERNAL_URL and the door's matcher"
    when 503 then raise Failure, "#{where(path)} has creator links off: #{said.presence || "set FS_CREATOR_LINK_KEY in /etc/fourier-sampling/env and restart fourier-web"}"
    when 590..599 then raise Failure, "#{where(path)} did not answer (#{response.code}) at #{@base} -- check that fourier-web is up, Caddy's :5181 door is loaded and the host firewall admits the booru's network"
    else raise Failure, "#{where(path)} answered #{response.code}: #{said.presence || "no reason given"}"
    end
  end

  def parse(path, response)
    data = JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
    raise Failure, "#{where(path)} answered #{response.code} with JSON that is not an object" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Failure, "#{where(path)} answered #{response.code} with something that is not JSON -- check that #{@base} is Caddy's :5181 door to fourier-sampling" unless response.code.in?(590..599)

    {}
  end

  def link(row)
    ok = row.is_a?(Hash) && row["hash"].to_s.match?(/\A[0-9a-f]{32}\z/) && row["url"].is_a?(String) && row["url"].start_with?("https://") &&
      row["createdAt"].is_a?(Numeric) && row["expiresAt"].is_a?(Numeric)
    raise Failure, "fourier-sampling answered a link without hash, https url, createdAt and expiresAt -- check FS_PUBLISHED_BASE in /etc/fourier-sampling/env" unless ok

    Link.new(hash_id: row["hash"], url: row["url"], title: row["title"].to_s, created_at: Time.zone.at(row["createdAt"] / 1000.0),
             ends_at: Time.zone.at(row["expiresAt"] / 1000.0), post_count: row["post_count"].to_i)
  end
end
