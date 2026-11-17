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
# It opens a popup rather than a frame. Framing was tried first and measured
# against the real provider, which answers X-Frame-Options: SAMEORIGIN from a
# different origin than the booru -- so the frame could never load, and every
# sign-in would have waited out a fallback timer staring at a blank box. The
# popup is the path that works, so it is the path the panel offers, plainly and
# with the caveat stated up front: a popup can be blocked, and a user who does
# not know that just sees nothing happen.
class MatrixSigninComponent < ApplicationComponent
  POLL_INTERVAL_MS = 2_000
  # Polling stops eventually; a login page left open overnight should not talk
  # to the server until the tab closes.
  POLL_CEILING_MS = 5 * 60 * 1_000

  attr_reader :matrix_id, :heading, :account, :url

  # @param matrix_id [String, nil] the already-verified MXID, if this request
  #   carried one. Present means the panel opens in its linked state and never
  #   starts the flow at all.
  # @param account [MatrixAccount, nil] that MXID's booru account, given when
  #   the viewer is signed in to Matrix and NOT to the booru. That happens when
  #   they signed out of the booru, or when no account could be made under their
  #   Matrix username; the panel says which, and what to do (operator,
  #   2026-11-07: the fallback for the account made on the first booru visit).
  # @param url [String] where signing in goes on to
  def initialize(matrix_id: nil, heading: "Matrix", account: nil, url: nil)
    super
    @matrix_id = matrix_id.presence
    @heading = heading
    @account = account
    @url = url
  end

  def linked?
    matrix_id.present?
  end

  # Lifts the sign-out and signs the Matrix identity's account in
  # (SessionsController#new).
  def continue_url
    login_path(matrix: 1, url: url)
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
      pollIntervalMs: POLL_INTERVAL_MS,
      pollCeilingMs: POLL_CEILING_MS,
      doneUrl: url || root_path,
    }
  end
end
