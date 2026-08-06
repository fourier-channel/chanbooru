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
# In development the same header can be set directly (e.g. curl -H
# 'X-Fourier-Identity: @alice:41chan.net') to exercise the gated actions.
module FourierIdentity
  HEADER = "HTTP_X_FOURIER_IDENTITY"

  # @return [String, nil] the MXID for this request, or nil if the request did
  #   not carry a fourier-auth identity.
  def self.current(request)
    request.get_header(HEADER).to_s.strip.presence
  end

  # @return [Boolean] true if the request's verified identity is `matrix_id`.
  def self.matches?(request, matrix_id)
    id = current(request)
    id.present? && matrix_id.present? && id.casecmp?(matrix_id)
  end
end
