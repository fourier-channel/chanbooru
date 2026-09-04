# frozen_string_literal: true

# What the Manage Session bar's monitors actually observed on this request.
#
# The design is the operator's (2026-09-04): a monitor announces itself from
# its FIRST READ of the object it purports to observe -- the label is derived
# from the environment, not asserted -- and that label is checked against a
# programmed constant, the one GO. Green therefore proves "I am reading the
# right object and it verifies" rather than summarising an assumption, and
# there is no exhaustive no-go list to maintain. The label re-derives on
# every read, so an object that changes identity mid-session drops the GO
# instead of coasting on its first impression.
#
# Cookie VALUES never leave the server: each is reduced to an 8-hex sha256
# digest -- enough for a human to see "same token" / "different token" and
# nothing else.
module SessionObservation
  FOURIER_COOKIE = "fourier_session"

  def self.digest(value)
    return nil if value.blank?

    Digest::SHA256.hexdigest(value.to_s)[0, 8]
  end

  # The two monitor descriptors plus the server clock the tickers count from.
  def self.for_request(request, user)
    { booru: booru(request, user), matrix: matrix(request), now: Time.zone.now.to_i }
  end

  def self.booru(request, user)
    name = Danbooru.config.session_cookie_name
    raw = request.cookies[name]
    session = request.session
    signed_in = user.present? && !user.is_anonymous?

    current = signed_in && session[:login_id].present? ? LoginSession.find_by(user_id: user.id, login_id: session[:login_id]) : nil
    previous = signed_in ? LoginSession.where(user_id: user.id).where.not(status: "active").order(updated_at: :desc).first : nil

    {
      expect: "cookie:#{name}",
      observed: (raw.present? ? "cookie:#{name}" : nil),
      digest: digest(raw),
      signed_in: signed_in,
      name: (signed_in ? user.name : nil),
      level: (signed_in ? user.level_string : nil),
      # The Rails session cookie re-issues with a fresh expiry on every
      # response, so "last refresh" is this page load; started_at is the
      # session's own birth.
      started_at: epoch(session[:started_at]),
      authenticated_at: epoch(session[:last_authenticated_at]),
      current_session: (current && { digest: digest(current.login_id), seen_at: current.last_seen_at&.to_i }),
      previous_session: (previous && { digest: digest(previous.login_id), status: previous.status, ended_at: previous.updated_at.to_i }),
    }
  end

  def self.matrix(request)
    raw = request.cookies[FOURIER_COOKIE]
    mxid = FourierIdentity.current(request)

    {
      expect: "cookie:#{FOURIER_COOKIE}",
      observed: (raw.present? ? "cookie:#{FOURIER_COOKIE}" : nil),
      digest: digest(raw),
      linked: mxid.present?,
      matrix_id: mxid,
      verified_at: (mxid.present? ? Time.zone.now.to_i : nil),
      gate: gate_state(raw, mxid),
      # Forward-contract: when fourier-auth starts publishing session info
      # through the verify subrequest (previous token digest and end,
      # expiry, next refresh), nginx hands it to Rails in
      # X-Fourier-Session-Info as JSON and it rides straight through here.
      # Until then the fields are absent and the tooltip says so, rather
      # than inventing a refresh schedule chanbooru does not know.
      info: parse_info(request.get_header("HTTP_X_FOURIER_SESSION_INFO")),
    }
  end

  # Cookie without identity is the one ambiguous state: the session died at
  # the gate, or the gate itself did. The bar renders it as STALE, never as
  # signed-out -- the viewer still owns the cookie (operator: a stale-state
  # light that is not actually stale yet).
  def self.gate_state(raw, mxid)
    return "linked" if mxid.present?
    return "stale" if raw.present?

    "absent"
  end

  def self.parse_info(header)
    return nil if header.blank?

    data = JSON.parse(header)
    data.is_a?(Hash) ? data.slice("previous_digest", "previous_ended_at", "expires_at", "refresh_at") : nil
  rescue JSON::ParserError
    nil
  end

  def self.epoch(value)
    return nil if value.blank?

    value.to_time.to_i
  rescue StandardError
    nil
  end
end
