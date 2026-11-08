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
module MediaDoorAsk
  PARAM = "media_door"
  TOKEN_HOLDER = "token_holder"

  module_function

  # @return [Boolean] whether this request is fourier-auth's ask for a signed-in
  #   Matrix reader
  def token_holder?(request, params)
    return false unless params[PARAM].to_s == TOKEN_HOLDER

    from_media_door?(request)
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
      Rails.logger.error("media door ask: #{door.inspect} resolves to no address, so no #{PARAM}=#{TOKEN_HOLDER} ask is honoured and a Matrix reader outside a placed post's rooms gets the signed-out (rating g) answer; fourier_media_door must name fourier-auth's compose service")
    else
      Rails.logger.error("media door ask: ignored #{PARAM}=#{TOKEN_HOLDER} from #{peer}, which is not #{door.inspect} (#{@door_addresses.join(", ")}); answered as signed out. If fourier-auth's compose service is not #{door.inspect}, set fourier_media_door to it")
    end
    false
  end
end
