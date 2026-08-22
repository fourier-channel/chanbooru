# frozen_string_literal: true

# Can the Matrix sign-in flow be shown in a frame, or must it be a popup?
#
# This cannot be answered from the browser. The sign-in document lives on the
# identity provider's origin, so its headers are unreadable across origins -- and
# a frame refused by X-Frame-Options can still fire `load`, so there is nothing
# reliable to observe either. Guessing wrong costs a blank box on the login page
# for however long the fallback timer runs.
#
# The SERVER has no such limit. It follows the login redirect one hop and reads
# the provider's framing headers directly, which is a definite answer instead of
# a guess.
#
# Measured on this deployment 2026-08-22: the provider answers
# `X-Frame-Options: SAMEORIGIN`, and the booru and the provider are different
# origins, so framing is refused. That is why the login page shows the button
# rather than a frame -- not a preference, a measurement. This class re-measures
# rather than hardcoding it, so switching providers fixes itself.
#
# Fails SAFE in every direction: any error, timeout, or ambiguity answers "do not
# frame", because the popup path always works and a wrong "yes" is the only
# answer that produces a broken page.
class MatrixSigninFrameability
  CACHE_TTL = 1.hour
  # The login page must not wait on someone else's server. Two seconds is
  # already generous for one HEAD against the identity provider.
  TIMEOUT = 2

  class << self
    # @param login_url [String] the site-relative sign-in path, e.g. "/fourier/login"
    # @return [Boolean] true only if the provider positively permits framing here.
    def frameable?(login_url)
      case Danbooru.config.matrix_signin_frame_mode.to_s
      in "always" then true
      in "never" then false
      else probe(login_url)
      end
    end

    private

    def probe(login_url)
      Rails.cache.fetch(cache_key(login_url), expires_in: CACHE_TTL) { measure(login_url) }
    rescue StandardError => e
      DanbooruLogger.log(e, login_url: login_url)
      false
    end

    def cache_key(login_url)
      "matrix-signin-frameable:#{Danbooru.config.canonical_url}:#{login_url}"
    end

    def measure(login_url)
      base = Danbooru.config.canonical_url.to_s
      return false if base.blank?

      http = Danbooru::Http.external.timeout(TIMEOUT)
      response = http.no_follow.head(File.join(base, login_url))

      # Deliberately NOT Danbooru::Http#redirect_url here. It answers nil for
      # "did not redirect" AND for "the request failed", and those need opposite
      # decisions: a gate serving sign-in from our own origin is frameable, a
      # gate answering 502 is not. Reading the status directly keeps them apart
      # -- an earlier version conflated them and framed a 502.
      if response.status.redirect?
        target = response.headers["Location"].to_s
        return false if target.blank?

        permits_framing?(http, target, embedder: base)
      elsif response.status.success?
        # Served from our own origin; still ask, because our own proxy may set a
        # framing header of its own.
        permits_framing?(http, File.join(base, login_url), embedder: base)
      else
        false
      end
    end

    # X-Frame-Options and CSP frame-ancestors, in the order browsers apply them:
    # a CSP frame-ancestors directive supersedes X-Frame-Options where both are
    # present.
    def permits_framing?(http, url, embedder:)
      response = http.no_follow.head(url)
      csp = response.headers["Content-Security-Policy"].to_s
      xfo = response.headers["X-Frame-Options"].to_s.strip.downcase

      ancestors = csp[/frame-ancestors([^;]*)/i, 1]
      return frame_ancestors_allow?(ancestors, embedder) if ancestors.present?

      return false if xfo.start_with?("deny")
      # SAMEORIGIN permits only the provider's own origin. The booru is a
      # different host, so this is a refusal -- which is exactly the case that
      # made the frame worth measuring instead of assuming.
      return same_origin?(url, embedder) if xfo.start_with?("sameorigin")

      # No framing header at all: the browser will allow it.
      true
    end

    def frame_ancestors_allow?(directive, embedder)
      sources = directive.to_s.split.map { _1.strip.downcase }.reject(&:blank?)
      return false if sources.include?("'none'")
      return true if sources.include?("*")

      host = Addressable::URI.parse(embedder).host.to_s.downcase
      sources.any? do |source|
        next false if source.start_with?("'")
        source_host = Addressable::URI.parse(source).host.to_s.downcase
        source_host.presence == host || source.delete_prefix("*.").then { |bare| host.end_with?(bare) && bare.present? }
      end
    rescue StandardError
      false
    end

    def same_origin?(a, b)
      ua = Addressable::URI.parse(a)
      ub = Addressable::URI.parse(b)
      ua.scheme == ub.scheme && ua.host == ub.host && ua.inferred_port == ub.inferred_port
    rescue StandardError
      false
    end
  end
end
