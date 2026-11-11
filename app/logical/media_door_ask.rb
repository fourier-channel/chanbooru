# frozen_string_literal: true

# THE MEDIA DOOR'S ASK FOR A MATRIX READER.
#
# The md5 ask fourier-auth sends carries no credentials, so the booru reads it
# as signed out: rating g only (operator, 2026-11-08), and for a tokenless
# image request that is right. A Matrix reader is not signed out, and the
# door asks about them by their Matrix id instead, in the one mode below.
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
#
# OUTSIDE ITS ROOMS, A PLACED POST IS THE BOORU'S TO DECIDE (operator,
# 2026-11-11: "we let the booru surface, as the more permissive of the two
# surfaces due to the explicit creator grant, decide ... putting the post
# within a gallery at all is unlocking gate 3 while it's on that gallery
# space"). The same ask answers `hidden_outside_rooms` as well: hidden from
# the reader by every gate, Gate 3 as it stands for a reader in none of the
# post's rooms -- so open only for a post that is not a Matrix post, or one
# placed on a public gallery (MatrixViewerRooms.placed_grant) with rooms
# left. fourier-auth reads it for a reader the rooms refused, so a Gold
# reader is handed the placed post a Gold viewer is drawn on the gallery, and
# a member below Gold is refused it, as their gallery leaves its card out.
module MediaDoorAsk
  PARAM = "media_door"
  MATRIX_READER = "matrix_reader"
  MATRIX_ID = "matrix_id"

  # What the door loses when its ask comes from a peer that is not the door.
  LOST = "fourier-auth cannot read the answer and refuses every Matrix image a booru post holds (503)"

  module_function

  # @return [String, nil] the Matrix reader fourier-auth asks for, when this
  #   request is its ask (see above)
  def matrix_reader(request, params)
    return nil unless params[PARAM].to_s == MATRIX_READER

    mxid = params[MATRIX_ID].to_s.downcase
    return nil unless FourierPostCreator.valid_mxid?(mxid)

    from_media_door?(request) ? mxid : nil
  end

  # For each post holding one of the md5s in `tags` (md5:a,b,...), whether it
  # is hidden from the Matrix reader `mxid` by every gate but the rooms, and
  # whether it is when the rooms do not hold them (see above). The reader is
  # their linked booru account; one with none yet (a Matrix account makes it
  # on its first booru request) or a deleted one is a stranger, as their booru
  # page would treat them. Nothing is made, nobody is signed in and nothing is
  # recorded: this asks about a reader, it is not one.
  #
  # @return [Array<Hash>] {md5:, hidden:, hidden_outside_rooms:} for each post found
  def hidden_from_reader(tags, mxid)
    raise ActionController::BadRequest, "#{PARAM}=#{MATRIX_READER} asks about tags=md5:<md5>[,<md5>...] (up to 20), nothing else" unless tags.to_s.match?(MembersOnly::ANONYMOUS_MD5_QUERY)

    reader = User.find_by(matrix_id: mxid)
    reader = User.anonymous if reader.nil? || reader.is_deleted?
    md5s = tags.to_s.delete_prefix("md5:").downcase.split(",")
    Post.unscoped do
      posts = Post.where(md5: md5s).select(:id, :md5, :is_banned, :bit_flags, :tag_string, :room_ids).to_a
      hidden = withheld_ids(posts, reader)
      posts.map { |post| { md5: post.md5, hidden: hidden.include?(post.id), hidden_outside_rooms: hidden.include?(post.id) || closed_outside_rooms?(post) } }
    end
  end

  # Whether Gate 3 hides `post` from a reader in none of its rooms: a Matrix
  # post not placed on a public gallery, or one with no rooms left (redaction
  # still wins). Post#hidden_by_matrix_rooms? with no room of theirs.
  def closed_outside_rooms?(post)
    return false if post.room_ids == [MatrixViewerRooms::NOT_MATRIX]

    post.room_ids.empty? || MatrixViewerRooms.placed_grant.exclude?(post.id)
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
  def from_media_door?(request)
    door = Danbooru.config.fourier_media_door
    return true if door.nil?

    peer = request.remote_addr.to_s
    return true if @door_addresses&.include?(peer)

    @door_addresses = Resolv.getaddresses(door)
    return true if @door_addresses.include?(peer)

    if @door_addresses.empty?
      Rails.logger.error("media door ask: #{door.inspect} resolves to no address, so no #{PARAM}=#{MATRIX_READER} ask is honoured and #{LOST}; fourier_media_door must name fourier-auth's compose service")
    else
      Rails.logger.error("media door ask: ignored #{PARAM}=#{MATRIX_READER} from #{peer}, which is not #{door.inspect} (#{@door_addresses.join(", ")}); answered as signed out, so #{LOST}. If fourier-auth's compose service is not #{door.inspect}, set fourier_media_door to it")
    end
    false
  end
end
