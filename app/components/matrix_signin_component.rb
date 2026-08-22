# frozen_string_literal: true

# The "sign in with Matrix" panel: links the viewer's Matrix identity through
# fourier-auth without navigating the page it sits on.
#
# Sign-in finishes somewhere this page cannot read -- a document on the identity
# provider's origin, framed or in a popup. Rather than trying to talk to it, the
# panel polls this site's own /fourier_identity: whichever way the flow ended, it
# left a fourier_session cookie behind, and the proxy turns that into a verified
# identity on the next same-origin request. One completion mechanism for both
# paths, coupled to neither.
#
# The frame is attempted first and falls back to a popup, because identity
# providers commonly refuse to be framed (X-Frame-Options / frame-ancestors) and
# a refusal is not reliably detectable from script -- a blocked frame can still
# fire load. So the fallback is driven by "nothing has happened for a while"
# rather than by a detection that would sometimes lie, and the escape hatch is
# on screen the whole time instead of appearing only when a guess fires.
class MatrixSigninComponent < ApplicationComponent
  # How long a framed attempt gets before the popup is offered as the way out.
  FRAME_GRACE_MS = 6_000
  POLL_INTERVAL_MS = 2_000
  # Polling stops eventually; a login page left open overnight should not talk
  # to the server until the tab closes.
  POLL_CEILING_MS = 5 * 60 * 1_000

  attr_reader :matrix_id, :heading

  # @param matrix_id [String, nil] the already-verified MXID, if this request
  #   carried one. Present means the panel opens in its linked state and never
  #   starts the flow at all.
  def initialize(matrix_id: nil, heading: "Matrix")
    super
    @matrix_id = matrix_id.presence
    @heading = heading
  end

  def linked?
    matrix_id.present?
  end

  # Only frame when the provider positively permits it. Asked once and cached;
  # see MatrixSigninFrameability for why the browser cannot answer this and the
  # server can.
  def frameable?
    return false if linked?

    MatrixSigninFrameability.frameable?(login_url)
  end

  def login_url
    "/fourier/login"
  end

  def logout_url
    "/fourier/logout"
  end

  def config
    {
      statusUrl: Rails.application.routes.url_helpers.fourier_identity_path(format: :json),
      loginUrl: login_url,
      logoutUrl: logout_url,
      frameGraceMs: FRAME_GRACE_MS,
      pollIntervalMs: POLL_INTERVAL_MS,
      pollCeilingMs: POLL_CEILING_MS,
    }
  end
end
