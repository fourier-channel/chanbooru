# frozen_string_literal: true

# Reports whether THIS request carries a verified Matrix identity.
#
# The login page's Matrix panel polls this. It exists because the sign-in flow
# finishes somewhere the page cannot see: in a framed document on the identity
# provider's origin, or in a popup window. Neither can be read across origins,
# and neither can be relied on to postMessage back. What both DO leave behind is
# the fourier_session cookie -- which the reverse proxy turns into a verified
# identity header on the next same-origin request. So the page asks its own
# origin "am I linked yet", which works identically for both paths and couples
# to nothing.
#
# Read-only, and it discloses only what the caller's own request already proves.
class FourierIdentityController < ApplicationController
  respond_to :json

  def show
    skip_authorization
    mxid = FourierIdentity.current(request)
    render json: { linked: mxid.present?, matrix_id: mxid }, status: :ok
  end
end
