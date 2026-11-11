# frozen_string_literal: true

# THE MEDIA DOOR'S SIGNED-IN ASK.
#
# Signed-out viewers get safe mode: rating g only (operator, 2026-11-08:
# "only sfw images to signed out viewers"; SessionLoader#set_safe_mode). The
# md5 ask fourier-auth sends carries no credentials, so the booru reads it as
# signed out, and for a tokenless image request that is right.
#
# One caller of that ask is NOT signed out: fourier-auth's Matrix media door
# asks it for a token holder the room check refused, so that a post placed on
# a public creator gallery passes Gate 3 for them (operator, 2026-11-01;
# MembersOnly.placed_ids). That reader is signed in to Matrix, and the flip
# must not narrow what they saw. fourier-auth says so with
# `media_door=token_holder`, and the booru honours it only when the TCP peer
# is fourier-auth itself (Danbooru.config.fourier_media_door), the same peer
# check FourierIdentity makes for the proxy. The ask is otherwise unchanged:
# still anonymous, still only shown and placed posts
# (MembersOnly.anonymous_md5_rows), only without the rating cut.
#
# Fails closed: the parameter from any other peer is ignored (and logged),
# so the request keeps safe mode.
#
# A MATRIX IMAGE FOLLOWS ITS POST, IN ITS ROOMS TOO (operator, 2026-11-11).
# The rooms decide who may fetch a Matrix image (Gate 3), but a room member
# the booru hides the post from -- a sensitive post below Gold (gate 1), a
# deleted or jailed one (gate 4), every gate but the rooms -- is refused the
# image as well, and Technetium pops the message out of the room. For that
# fourier-auth asks with `media_door=matrix_reader&matrix_id=<the reader>`,
# from the same peer only, and is answered {md5, hidden} for every post that
# holds one of the md5s (#hidden_from_reader). An md5 no post holds is
# absent, and the rooms alone decide it. From any other peer the mode is
# ignored and logged, and the ask is answered as a stranger's: rows with no
# `hidden`, which fourier-auth refuses to read, so its image is refused.
module MediaDoorAsk
  PARAM = "media_door"
  TOKEN_HOLDER = "token_holder"
  MATRIX_READER = "matrix_reader"
  MATRIX_ID = "matrix_id"

  # What a mode loses when its ask comes from a peer that is not the door.
  LOST = {
    TOKEN_HOLDER => "a Matrix reader outside a placed post's rooms gets the signed-out (rating g) answer",
    MATRIX_READER => "fourier-auth cannot read the answer and refuses every Matrix image a booru post holds (503)",
  }.freeze

  module_function

  # @return [Boolean] whether this request is fourier-auth's ask for a signed-in
  #   Matrix reader
  def token_holder?(request, params)
    return false unless params[PARAM].to_s == TOKEN_HOLDER

    from_media_door?(request, TOKEN_HOLDER)
  end

  # @return [String, nil] the Matrix reader fourier-auth asks for, when this
  #   request is its in-room ask (see above)
  def matrix_reader(request, params)
    return nil unless params[PARAM].to_s == MATRIX_READER

    mxid = params[MATRIX_ID].to_s.downcase
    return nil unless FourierPostCreator.valid_mxid?(mxid)

    from_media_door?(request, MATRIX_READER) ? mxid : nil
  end

  # Whether each post holding one of the md5s in `tags` (md5:a,b,...) is
  # hidden from the Matrix reader `mxid`, by every gate but the rooms: the
  # question MatrixViewerRooms.placed_grant asks for a signed-out viewer.
  # The reader is their linked booru account; one with none yet (a Matrix
  # account makes it on its first booru request) or a deleted one is a
  # stranger, as their booru page would treat them. Nothing is made, nobody is
  # signed in and nothing is recorded: this asks about a reader, it is not one.
  #
  # @return [Array<Hash>] {md5:, hidden:} for each post found
  def hidden_from_reader(tags, mxid)
    raise ActionController::BadRequest, "#{PARAM}=#{MATRIX_READER} asks about tags=md5:<md5>[,<md5>...] (up to 20), nothing else" unless tags.to_s.match?(MembersOnly::ANONYMOUS_MD5_QUERY)

    reader = User.find_by(matrix_id: mxid)
    reader = User.anonymous if reader.nil? || reader.is_deleted?
    md5s = tags.to_s.delete_prefix("md5:").downcase.split(",")
    Post.unscoped do
      posts = Post.where(md5: md5s).select(:id, :md5, :is_banned, :bit_flags, :tag_string).to_a
      hidden = withheld_ids(posts, reader)
      posts.map { |post| { md5: post.md5, hidden: hidden.include?(post.id) } }
    end
  end

  # Whether `post`, already hidden from `user`, is a Matrix image the door
  # refuses them for its post, so Technetium pops it from the room
  # (FourierTagSourcesController#show answers `withheld`). Only a post placed
  # in rooms that hold this reader: one hidden by the rooms alone is not, and
  # a new Matrix post is closed to every room ({}) until its own are known,
  # so its picture does not pop for the people it was posted to.
  def withheld?(post, user)
    post.room_ids.to_a.any?(&:positive?) && !post.hidden_by_matrix_rooms?(user) && withheld_ids([post], user).include?(post.id)
  end

  # The ids among `posts` hidden from `reader` by every gate but the rooms:
  # what the media door refuses a room member the image for.
  def withheld_ids(posts, reader)
    hidden = Post.hidden_ids_among(posts.map(&:id), reader, rooms: false)
    posts.select { |post| hidden.include?(post.id) || post.banblocked?(reader) }.map(&:id)
  end

  # The media door's addresses are looked up again only when a peer does not
  # match them, as FourierIdentity.from_proxy? does.
  def from_media_door?(request, mode)
    door = Danbooru.config.fourier_media_door
    return true if door.nil?

    peer = request.remote_addr.to_s
    return true if @door_addresses&.include?(peer)

    @door_addresses = Resolv.getaddresses(door)
    return true if @door_addresses.include?(peer)

    if @door_addresses.empty?
      Rails.logger.error("media door ask: #{door.inspect} resolves to no address, so no #{PARAM}=#{mode} ask is honoured and #{LOST.fetch(mode)}; fourier_media_door must name fourier-auth's compose service")
    else
      Rails.logger.error("media door ask: ignored #{PARAM}=#{mode} from #{peer}, which is not #{door.inspect} (#{@door_addresses.join(", ")}); answered as signed out, so #{LOST.fetch(mode)}. If fourier-auth's compose service is not #{door.inspect}, set fourier_media_door to it")
    end
    false
  end
end
