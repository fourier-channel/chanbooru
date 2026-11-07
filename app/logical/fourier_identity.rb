# frozen_string_literal: true

# Resolves the VERIFIED Matrix identity (MXID) of the current request, as
# established by fourier-auth.
#
# Trust boundary: in production, fourier-auth verifies the fourier_session and
# the reverse proxy passes the resolved MXID to Rails in the `X-Fourier-Identity`
# request header. nginx MUST strip any client-supplied value for that header and
# set it ONLY from the verified session -- Rails trusts the header precisely
# because the proxy is the one setting it. (If that guarantee is not in place,
# this returns whatever a client sent, which would be a spoofable identity, so
# the nginx rule is load-bearing.)
#
# The nginx rule covers what arrives through nginx, and nothing else. Rails
# also listens on the container network, where fourier-auth, the tunnel and
# the other services reach it directly, and a header sent that way passed
# straight through. Once the identity started signing people in to booru
# accounts (MatrixAccount) that was a way into any account, so the header is
# now honoured only when the connection itself comes from the proxy:
# Danbooru.config.fourier_identity_proxy, resolved to its addresses and matched
# against the TCP peer. REMOTE_ADDR is that peer -- puma is not told to replace
# it from a forwarded header -- so a client cannot claim it.
#
# In development the same header can be set directly (e.g. curl -H
# 'X-Fourier-Identity: @alice:41chan.net') to exercise the gated actions: the
# proxy setting is nil there, which trusts any peer.
module FourierIdentity
  HEADER = "HTTP_X_FOURIER_IDENTITY"

  # The peer is judged once a request and the verdict kept on it: a page asks
  # for the identity several times, and a refused one would otherwise be
  # looked up and logged again each time.
  #
  # @return [String, nil] the MXID for this request, or nil if the request did
  #   not carry a fourier-auth identity, or carried one from a peer that is not
  #   the proxy.
  def self.current(request)
    mxid = request.get_header(HEADER).to_s.strip.presence
    return nil if mxid.nil?

    request.set_header("fourier_identity.from_proxy", from_proxy?(request)) unless request.has_header?("fourier_identity.from_proxy")
    mxid if request.get_header("fourier_identity.from_proxy")
  end

  # The proxy's addresses are looked up again only when a peer does not match
  # them, so a recreated proxy container with a new address is picked up on its
  # first request and an unchanged one costs no lookup at all.
  #
  # @return [Boolean] whether the request's TCP peer is the identity proxy
  def self.from_proxy?(request)
    proxy = Danbooru.config.fourier_identity_proxy
    return true if proxy.nil?

    peer = request.get_header("REMOTE_ADDR").to_s
    return true if @proxy_addresses&.include?(peer)

    @proxy_addresses = Resolv.getaddresses(proxy)
    return true if @proxy_addresses.include?(peer)

    # Not silent: a proxy name that resolves to nothing turns every Matrix
    # sign-in away, and a header from elsewhere is someone trying one. The
    # identity itself is not logged. Logged as errors, because production
    # keeps nothing below :error (Danbooru.config.log_level).
    if @proxy_addresses.empty?
      Rails.logger.error("fourier identity: the proxy #{proxy.inspect} resolves to no address, so no request's X-Fourier-Identity is honoured; fourier_identity_proxy must name the reverse proxy's compose service")
    else
      Rails.logger.error("fourier identity: ignored X-Fourier-Identity from #{peer}, which is not the proxy #{proxy.inspect} (#{@proxy_addresses.join(", ")}); if the reverse proxy is not #{proxy.inspect}, set fourier_identity_proxy to its compose service")
    end
    false
  end

  # @return [Boolean] true if the request's verified identity is `matrix_id`.
  def self.matches?(request, matrix_id)
    id = current(request)
    id.present? && matrix_id.present? && id.casecmp?(matrix_id)
  end
end
