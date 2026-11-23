# frozen_string_literal: true

# Tell the Matrix rooms a post's picture sits in that who may see it changed:
# a jail, a deletion, a restricted (sensitive) tag, or their undoing
# (FourierTagPropagation.visibility_changed!, PushVisibilityJob).
#
#   POST <fourier-tunnel>/visibility/<post id>  {"rooms": [...], "mxcs": [...]}
#
# fourier-tunnel (visibility.js) rewrites the post's net.41chan.media.tags
# state in each of those rooms with the content the room already holds and a
# new updated_at, so every client syncing the room hears a change. Technetium
# then reads the post again from this booru, and the booru's answer decides:
# withheld pops the picture, shown brings it back. Nothing here sends tags or
# a reason: a room member learns only that the state was rewritten.
#
# The tunnel answers 202 once the push is queued; the room walk's outcome is
# in the tunnel's log ("[visibility] post #N: ..."). A push that is lost is
# still caught by Technetium's one-minute re-read of the pictures on screen.
class MatrixVisibilityPush
  # Worth trying again: the tunnel did not answer, or answered 5xx.
  class Unanswered < StandardError; end

  TIMEOUT = 5
  # The tunnel's own limits (visibility.js MAX_ROOMS, MAX_MXCS, MXC).
  MAX_ROOMS = 1000
  MAX_MXCS = 1000
  MXC = %r{\Amxc://[A-Za-z0-9.\-:\[\]]{1,255}/[A-Za-z0-9_-]{1,255}\z}

  def initialize(post_id, url: Danbooru.config.fourier_tunnel_internal_url, http: Danbooru::Http.internal)
    @post_id = post_id
    @base = url.to_s.chomp("/")
    @http = http
  end

  # :pushed (queued by the tunnel), :no_rooms (nobody to tell) or :refused
  # (the tunnel will refuse this push however often it is sent: logged with
  # its fix). Raises Unanswered when trying again may help.
  def push!
    ids = Post.where(id: @post_id).pick(:room_ids).to_a.select(&:positive?)
    rooms = MatrixRoom.where(id: ids).order(:id).pluck(:room_id).grep(MatrixRoom::ROOM_ID)
    return :no_rooms if rooms.empty?

    mxcs = PostMxc.where(post_id: @post_id).order(:id).pluck(:mxc).grep(MXC)
    if rooms.size > MAX_ROOMS || mxcs.size > MAX_MXCS
      DanbooruLogger.info("visibility push for post ##{@post_id}: #{rooms.size} rooms and #{mxcs.size} mxcs, past the tunnel's #{MAX_ROOMS}/#{MAX_MXCS}; the first #{MAX_ROOMS} rooms are told now, the rest learn of it from Technetium's one-minute re-read")
    end

    answer(post(rooms.first(MAX_ROOMS), mxcs.first(MAX_MXCS)))
  end

  private

  def post(rooms, mxcs)
    @http.timeout(TIMEOUT).no_follow.headers(Accept: "application/json").post("#{@base}/visibility/#{@post_id}", json: { rooms: rooms, mxcs: mxcs })
  end

  def answer(response)
    code = response.code
    return :pushed if code == 202

    said = said(response)
    case code
    when 590..599
      raise Unanswered, "fourier-tunnel did not answer (#{code}) at #{@base} -- check that the fourier-tunnel container is up and on the booru's Docker network (docker ps; docker network inspect danbooru_default)"
    when 500..589
      raise Unanswered, "fourier-tunnel answered #{code} at #{@base}: #{said} -- its log has the trace (docker logs fourier-tunnel)"
    when 404, 405
      refused(code, said, "the tunnel at #{@base} has no visibility push: deploy fourier-tunnel b8abc50 or later")
    else
      refused(code, said, "fix the push this booru builds (MatrixVisibilityPush) to the shape the tunnel names")
    end
  end

  def refused(code, said, fix)
    DanbooruLogger.info("visibility push for post ##{@post_id} refused by fourier-tunnel (#{code}): #{said}; not sent again, its rooms learn of the change from Technetium's one-minute re-read. Fix: #{fix}")
    :refused
  end

  def said(response)
    data = JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
    data.is_a?(Hash) ? [data["error"], data["fix"]].compact.join(" -- fix: ").presence || "no reason given" : "no reason given"
  rescue JSON::ParserError
    "an answer that is not JSON"
  end
end
