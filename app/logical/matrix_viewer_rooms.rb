# frozen_string_literal: true

# THE VIEWER'S ROOM SET for gate 3 for posts (fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md): the interned ids (MatrixRoom) of the
# Matrix rooms this viewer is joined to, plus
#
#   0   NOT_MATRIX -- every viewer holds it, so a post that is not a Matrix
#       post ({0}) is never narrowed by this gate;
#   -1  SITE_ASSET -- every viewer with a VERIFIED Matrix identity holds it:
#       an avatar, a room icon or an emote is seen by all of them.
#
# A post is shown when posts.room_ids overlaps this set (Post.hidden_from,
# PostQuery, Post#hidden_by_matrix_rooms?). The rooms come from fourier-auth's
# own door, GET <fourier_auth_internal_url>/verify?gate=rooms, with the
# viewer's OWN fourier_session cookie forwarded -- nobody can ask about
# someone else -- and the answer must name the MXID the proxy verified for
# this request (FourierIdentity, X-Fourier-Identity). Rooms no post has ever
# been placed in are not in matrix_rooms and drop out.
#
# FAIL CLOSED, LOUDLY (memory fail-loudly-no-fallbacks): no identity, no
# cookie, a 401, a 503, a timeout, an MXID that is not the viewer's, or a body
# that is not the documented shape -- the set is {0}: no Matrix post is shown,
# the failure is logged with its remedy and instrumented as
# "gate3.viewer_rooms_failed". Never shown by default.
#
# Cached in Rails.cache per MXID, about 45 s when the viewer has rooms and
# 10 s when they have none; a FAILURE is never cached (GATE3_CONTRACTS.md) --
# the next request asks again -- and the answer is memoized for the request. So leaving a room hides its
# posts within about a minute, as the image's own cache does.
class MatrixViewerRooms
  NOT_MATRIX = 0
  SITE_ASSET = -1

  COOKIE = "fourier_session"
  TIMEOUT = 2
  CACHE_WITH_ROOMS = 45.seconds
  CACHE_OTHERWISE = 10.seconds

  # The memo's kind for #placed_grant, forgotten when the record is written.
  PLACED_GRANT = :placed_grant
  # How long #placed_grant's check of the other gates is kept.
  PLACED_GRANT_CHECKED = 30.seconds

  class Failure < StandardError; end

  attr_reader :mxid, :request

  # Whether gate 3 narrows what `user` sees at all: only with the switch on
  # (gate3_matrix_posts_enforced?), and never for the pipeline -- the system
  # user and the posting bots. Admins are NOT exempt.
  def self.enforced_for?(user)
    Danbooru.config.gate3_matrix_posts_enforced? && !TagBanishment.pipeline?(user)
  end

  # The sorted set for `user`. The request's identity counts only when `user`
  # is the request's own viewer: asked about anyone else (a job, a console, a
  # check on another account) there is no identity to use, so {0}.
  def self.ids(user, request: CurrentUser.request)
    mxid = identity(user, request)
    return [NOT_MATRIX] if mxid.nil?

    CreatorVisibility.memoized([:matrix_viewer_rooms, mxid], user) { new(mxid, request).ids }
  end

  # The set as an integer[] literal for inlining into SQL. Inlined, not
  # bound: the planner must see the list to keep the plans measured on
  # 2026-10-15 (a bound or subqueried array picked a bitmap plan that took
  # seconds). Every element is an Integer, so nothing else can reach the SQL.
  def self.literal(user)
    "'{#{ids(user).map { |id| Integer(id) }.join(",")}}'::integer[]"
  end

  # THE PLACED-POST GRANT (operator, 2026-11-01): the posts placed on a
  # public creator's page someone opened, fresh (MembersOnly.placed_ids),
  # pass gate 3 for every viewer -- signed out, signed in, or a verified
  # Matrix identity outside the post's rooms: "an unlock for gate 3 on that
  # specific view surface and not scoped to any given user".
  #
  # Only a post a signed-out viewer may see, every gate but this one asked
  # (Post.hidden_ids_among, rooms: false), and whose md5 the md5 ask gives a
  # signed-out viewer (PostPolicy#can_see_media?: not banned, not taken
  # down): for a viewer outside the rooms the Matrix door asks the booru as
  # nobody, so a placed post gated, flagged, deleted, banned, under a hidden
  # prefix or hidden by its creator would draw for a viewer whose own gates
  # pass it -- a Gold viewer, an approver, an admin -- with its image refused.
  # Left out, its card is absent and the band goes on, as the hero band's do
  # (operator, 2026-11-01). Inside its rooms it shows as ever.
  #
  # Empty with no request at all, since a job or a console is no viewer --
  # LandingShowcaseCache's refresh searches as User.anonymous for a list
  # every viewer is served, long after a grant has lapsed. Read once a
  # request, the same for every viewer (CreatorVisibility.memoized): a page
  # asks it per post and per search, and nothing in front of the cache
  # absorbs the reads. And what the other gates leave of it is cached for
  # PLACED_GRANT_CHECKED, keyed on the record itself so a new placement is
  # asked about at once: asked as nobody, it cost a signed-in request 10-50
  # ms on production (2026-11-01, 22 posts placed), every request while a
  # public page has been viewed in the last two hours. A post gated or hidden
  # after the check keeps the grant that long, and only Gate 3's: every gate
  # of the viewer's own still hides it.
  def self.placed_grant(request: CurrentUser.request)
    return Set.new unless request

    CreatorVisibility.memoized(PLACED_GRANT, nil) do
      placed = MembersOnly.placed_ids
      next placed if placed.empty?

      Rails.cache.fetch(["gate3-placed-grant", Digest::SHA256.hexdigest(placed.sort.join(","))], expires_in: PLACED_GRANT_CHECKED) do
        Post.unscoped do
          kept = placed - Post.hidden_ids_among(placed.to_a, User.anonymous, rooms: false)
          Post.where(id: kept.to_a).select(:id, :is_banned, :bit_flags, :tag_string).reject { |post| post.banblocked?(User.anonymous) }.to_set(&:id)
        end
      end
    end
  end

  # What gate 3 shows `user`, as one row condition: the rooms meet theirs,
  # or the post is placed (#placed_grant) and has rooms left --
  # REDACTION STILL WINS (operator, 2026-10-15): a post whose every placement
  # was redacted, or a new one still closed, is {} and stays hidden. The
  # grant's ids are inlined as one literal, unnested, as the room set is
  # (#literal), and only when there are any, so an empty record reads
  # exactly as before. PostQuery#matrix_rooms_condition
  # filters on it; Post.hidden_from inverts it.
  def self.condition(user)
    overlap = "posts.room_ids && #{literal(user)}"
    placed = placed_grant
    return overlap if placed.empty?

    "(#{overlap} OR (cardinality(posts.room_ids) > 0 AND posts.id IN (SELECT unnest('{#{placed.map { |id| Integer(id) }.sort.join(",")}}'::integer[]))))"
  end

  def self.identity(user, request)
    viewer = CurrentUser.user
    return nil if request.nil? || user.nil? || viewer.nil?

    same = user.equal?(viewer) || (user.id.present? && user.id == viewer.id) || (user.is_anonymous? && viewer.is_anonymous?)
    same ? FourierIdentity.current(request) : nil
  end

  def initialize(mxid, request)
    @mxid = mxid
    @request = request
  end

  def ids
    cached = Rails.cache.read(cache_key)
    return cached if cached.is_a?(Array)

    begin
      found = [NOT_MATRIX, SITE_ASSET, *MatrixRoom.where(room_id: rooms).pluck(:id)].uniq.sort
    rescue Failure => e
      # NEVER cached (GATE3_CONTRACTS.md): the next request asks again.
      report(e)
      return [NOT_MATRIX]
    end
    Rails.cache.write(cache_key, found, expires_in: (found.size > 2) ? CACHE_WITH_ROOMS : CACHE_OTHERWISE)
    found
  end

  # The room id strings fourier-auth answers for this viewer, or Failure.
  def rooms
    cookie = request.cookies[COOKIE].to_s
    raise Failure, "the request carries #{mxid} but no #{COOKIE} cookie to ask fourier-auth with -- check that the proxy forwards the Cookie header to the booru" if cookie.blank?

    response = Danbooru::Http.internal.timeout(TIMEOUT).no_follow.cookies(COOKIE => cookie)
                             .headers(Accept: "application/json").get(url)
    raise Failure, failure(response) unless response.code == 200

    parse(response.body.to_s)
  end

  private

  def url
    "#{Danbooru.config.fourier_auth_internal_url.to_s.chomp("/")}/verify?gate=rooms"
  end

  def cache_key
    "gate3-viewer-rooms:#{Digest::SHA256.hexdigest(mxid)}"
  end

  def parse(body)
    data = begin
      JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      raise Failure, "#{url} answered 200 with something that is not JSON -- check that fourier-auth is new enough to answer gate=rooms"
    end
    raise Failure, "#{url} answered JSON that is not an object -- check fourier-auth's gate=rooms answer" unless data.is_a?(Hash)

    unless data["mxid"].is_a?(String) && data["mxid"].casecmp?(mxid)
      raise Failure, "#{url} answered for #{data["mxid"].inspect}, not for #{mxid} whom the proxy verified -- the cookie and the identity disagree; check the proxy's X-Fourier-Identity and fourier-auth's session store"
    end

    list = data["rooms"]
    unless list.is_a?(Array) && list.all? { |room| room.is_a?(String) && room.match?(MatrixRoom::ROOM_ID) }
      raise Failure, "#{url} answered rooms that are not a list of Matrix room ids -- check fourier-auth's gate=rooms answer"
    end
    if data.key?("count") && data["count"] != list.size
      raise Failure, "#{url} said count #{data["count"].inspect} but listed #{list.size} rooms -- a truncated answer; check fourier-auth's gate=rooms answer"
    end

    list
  end

  # What went wrong, and what to do about it. 59x are the HTTP client's own
  # codes for a request that got no answer.
  def failure(response)
    case response.code
    when 401
      "fourier-auth found no Matrix identity for this session (401) -- the viewer signs in again through Technetium"
    when 503
      "fourier-auth could not read Synapse (503) -- check fourier-auth's Synapse database grant and Synapse's health"
    when 597
      "asking #{url} timed out after #{TIMEOUT}s -- check that fourier-auth is up and not overloaded"
    when 590..599
      "could not reach #{url} (client code #{response.code}) -- check that fourier-auth is up and on the booru's Docker network, and fourier_auth_internal_url"
    else
      "#{url} answered HTTP #{response.code} -- check that fourier-auth is new enough to answer gate=rooms"
    end
  end

  def report(error)
    Rails.logger.warn("gate3: Matrix posts hidden from #{mxid}, whose rooms could not be read: #{error.message}")
    ActiveSupport::Notifications.instrument("gate3.viewer_rooms_failed", mxid: mxid, reason: error.message)
  end
end
