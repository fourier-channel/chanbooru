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
