# frozen_string_literal: true

# The Manage Session bar's data plane. `status` reports what THIS request's
# cookies and headers prove (the monitors' re-read, fetched on focus and
# after auth actions -- never on a heartbeat). `matrix_logout` is the one
# write chanbooru adds: expiring the fourier_session cookie, which rides
# this host and is therefore chanbooru's to expire; invalidating the
# server-side session is the gate's own POST /fourier/logout.
class ModulationSessionController < ApplicationController
  respond_to :json

  # Discloses only what the caller's own request already proves.
  def status
    skip_authorization
    render json: SessionObservation.for_request(request, CurrentUser.user), status: :ok
  end

  # The raw values of the session cookies THIS request carries -- the "show
  # tokens" step of the Manage Session card (operator ruling 2026-10-03). A
  # POST, so the CSRF check stands between a cross-site page and it; never
  # cached; and it can only ever return what the caller's own browser already
  # holds, by name, from the two the monitors read.
  def tokens
    skip_authorization
    response.headers["Cache-Control"] = "no-store"
    list = SessionObservation.token_cookie_names.filter_map do |name|
      value = request.cookies[name]
      { name: name, value: value, digest: SessionObservation.digest(value) } if value.present?
    end
    render json: { tokens: list }, status: :ok
  end

  # Purge, the server's half (operator ruling 2026-10-03: purge signs you out
  # of the site you are on and deletes what it stored). The page has already
  # signed out of the booru (DELETE /session) and of the gate's session
  # (POST /fourier/logout); this expires the gate's cookie on this host and
  # tells the browser to drop this origin's cache and storage. NOT "cookies":
  # Clear-Site-Data clears cookies for the whole registrable domain, which
  # would sign the viewer out of Technetium and every other 41chan app too.
  def purge
    skip_authorization
    cookies.delete(SessionObservation::FOURIER_COOKIE)
    cookies.delete(SessionObservation::FOURIER_COOKIE, domain: :all)
    response.headers["Clear-Site-Data"] = '"cache", "storage"'
    head :no_content
  end

  # Force-delete the fourier cookie (operator: "force delete the
  # fourier_session cookie upon logout") so the observed object goes away
  # rather than lingering as a dead token. Plain and domain-wide deletes
  # both, because the gate may have scoped the cookie either way.
  def matrix_logout
    skip_authorization
    cookies.delete(SessionObservation::FOURIER_COOKIE)
    cookies.delete(SessionObservation::FOURIER_COOKIE, domain: :all)
    head :no_content
  end
end
