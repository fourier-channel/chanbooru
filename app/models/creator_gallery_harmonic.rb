# frozen_string_literal: true

# A HARMONIC: one link card a creator builds for their gallery's Tuner
# (fourier-basis docs/design/CREATOR_TUNER.md rev 3, operator 2026-10-31).
# A link out to a site on the sitewide list, the creator's words, where each
# element sits on a 3x3 grid, and a background: one of the creator's own
# posts or a gradient.
#
# THE LIST AND ITS WORDS live in config/creator_harmonics.json, read here and
# by harmonic_model.js in the builder, so the two cannot disagree: which sites
# are carried and at which paths, the posts each refuses and the profile it
# points back to, and every refusal's sentence. A site taken off the list
# stops its harmonics drawing and counting at once; the rows stay, so its
# return restores them (sec 4.6).
#
# A harmonic is written only through the gallery's Save (CreatorGalleryLayout
# #save), upserted by id, so an admin's hide -- the staff_hidden_* columns and
# a CreatorHarmonicRemoval, both under the gallery's lock -- survives every
# owner Save (sec 4.2-4.5).
class CreatorGalleryHarmonic < ApplicationRecord
  CONFIG = JSON.parse(Rails.root.join("config/creator_harmonics.json").read, freeze: true)

  Site = Data.define(:key, :name, :group, :logo, :support, :adult, :host, :shape, :accept, :posts, :canonical)

  # A pattern in the list is unanchored; it must match the whole string here.
  def self.pattern(source)
    Regexp.new("\\A(?:#{source})\\z")
  end

  SITES = CONFIG["sites"].to_h do |site|
    [site["key"], Site.new(
      **site.symbolize_keys.slice(:key, :name, :group, :logo, :support, :adult, :shape),
      host: pattern(site["host"]),
      accept: site["accept"].map { |source| pattern(source) },
      posts: site["posts"].map { |source, profile| [pattern(source), profile] },
      canonical: site["canonical"].map { |source, spelling| [pattern(source), spelling] },
    )]
  end.freeze

  CTAS = CONFIG["ctas"].to_h.freeze
  PLACES = CONFIG["places"]
  ELEMENTS = CONFIG["elements"]
  GRADIENTS = CONFIG["gradients"].to_h.freeze
  LIMITS = CONFIG["limits"]
  DEFAULTS = CONFIG["defaults"]
  PROBLEMS = CONFIG["problems"]
  PLACEMENTS = %w[A B].freeze
  TRACKING = pattern(CONFIG["tracking"])
  REFUSED_HOSTS = { "shorteners" => "link_shortener", "hubs" => "link_hub", "invites" => "link_invite" }.freeze

  # Characters a reader cannot see or that turn text around: controls, the
  # soft hyphen, zero widths, bidi marks and overrides, the BOM.
  HIDDEN = /[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/
  # Spaces of every width, which no web address carries.
  SPACE = /[ \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/
  # What a path or query carries as itself (RFC 3986): an escape, or an
  # unreserved, sub-delim or path character. Anything else is escaped.
  ESCAPED = %r{%\h\h|[^A-Za-z0-9\-._~!$&'()*+,;=:@/?]}
  UNRESERVED = /\A[A-Za-z0-9\-._~]\z/

  belongs_to :creator_gallery
  belongs_to :staff_hidden_by, class_name: "User", optional: true

  # A pasted link, normalized (sec 5.1): https only, lowercased punycode host
  # with no www/m prefix and no trailing dot, no port but 443, no fragment, no
  # tracking parameters, no trailing or doubled slash, every escape in one
  # spelling, and the site's own spelling of the page. A site's own link, at
  # a path its entry accepts -- or the one refusal that says what is wrong and
  # what to paste instead.
  #
  # @return [Hash] { url:, host:, site: } or { problem:, vars: }
  def self.link(raw)
    text = raw.to_s.scrub.gsub(/\A[ \t\r\n\f\v]+|[ \t\r\n\f\v]+\z/, "")
    return refusal(:link_blank) if text.empty?
    return refusal(:link_hidden) if text.match?(HIDDEN)
    return refusal(:link_not_web) if text.match?(SPACE)

    scheme, rest = text.match(%r{\A([A-Za-z][A-Za-z0-9+.-]*)://(.*)\z}m)&.captures
    return refusal(:link_http) if scheme&.downcase == "http"
    return refusal(:link_not_web) unless scheme&.downcase == "https"

    authority, tail = rest.match(%r{\A([^/?#]*)(.*)\z}m).captures
    return refusal(:link_userinfo) if authority.include?("@")
    return refusal(:link_machine, host: authority) if authority.start_with?("[")

    name, port = authority.match(/\A(.*?)(?::([^:]*))?\z/).captures
    return refusal(:link_port, port: port) unless port.blank? || port == "443"

    # A full stop is a full stop however it is typed, as a browser reads it:
    # compatibility forms fold (NFKC), and the ideographic stop is a dot.
    host = name.unicode_normalize(:nfkc).downcase.tr("\u3002", ".").delete_suffix(".")
    host = Addressable::IDNA.to_ascii(host) unless host.ascii_only?
    return refusal(:link_not_web) unless host.match?(/\A[a-z0-9.-]+\z/)
    return refusal(:link_machine, host: host) if host == "localhost" || host.end_with?(".localhost") || host.match?(/\A[0-9.]+\z/) || host.exclude?(".")

    path, query = tail.sub(/#.*\z/m, "").split("?", 2).map { |part| escape(part) }
    path = path.to_s.squeeze("/")
    return refusal(:link_dots) if path.split("/").intersect?(%w[. ..])

    query = query.to_s.split("&").reject { |pair| pair.empty? || pair.split("=", 2).first.downcase.match?(TRACKING) }.join("&").presence
    labels = host.split(".")
    host = labels.drop(1).join(".") if labels.size > 2 && CONFIG["host_prefixes"].include?(labels.first)
    host = CONFIG["host_aliases"].fetch(host, host)

    refused = REFUSED_HOSTS.find { |list, _| CONFIG[list].any? { |domain| host == domain || host.end_with?(".#{domain}") } }
    return refusal(refused.last, host: host) if refused

    site = SITES.values.find { |entry| entry.host.match?(host) }
    return refusal(:link_unlisted, host: host) if site.nil?

    target = "#{host}#{path.delete_suffix("/")}#{"?#{query}" if query}"
    rule = site.canonical.find { |source, _| source.match?(target) }
    target = target.sub(*rule) if rule
    host = target[%r{\A[^/?]+}]
    url = "https://#{target}"
    return refusal(:link_long, length: url.length, max: LIMITS["url"]) if url.length > LIMITS["url"]

    post, profile = site.posts.lazy.map { |source, back| [source.match(target), back] }.find(&:first)
    return refusal(:link_post_profile, host: host, profile: profile.gsub(/\\(\d)/) { post[$1.to_i] }) if post && profile
    return refusal(:link_post, host: host, shape: site.shape) if post
    return refusal(:link_shape, site: site.name, shape: site.shape) if site.accept.none? { |source| source.match?(target) }

    { url: url, host: host, site: site.key }
  end

  # A path or query with each character it cannot carry as itself escaped,
  # each escape of one it can undone, and the rest in capitals: one spelling
  # of every address, and one URI.parse can read.
  def self.escape(part)
    part&.gsub(ESCAPED) do |found|
      if found.match?(/\A%\h\h\z/)
        found[1..].hex.chr.then { |char| char.match?(UNRESERVED) ? char : found.upcase }
      else
        found.bytes.map { |byte| format("%%%02X", byte) }.join
      end
    end
  end

  def self.refusal(key, **vars)
    { problem: key.to_s, vars: vars }
  end

  # A refusal's sentence, from the list's words.
  def self.sentence(key, **vars)
    PROBLEMS.fetch(key.to_s).gsub(/%\{(\w+)\}/) { vars.fetch($1.to_sym).to_s }
  end

  # The registrable end of a host, what the smallest card must still show:
  # "civitai.com" of "www.civitai.com".
  def self.domain(host)
    host.split(".").last(2).join(".")
  end

  def site_entry
    SITES[site]
  end

  def staff_hidden?
    staff_hidden_at.present?
  end

  def host
    url[%r{\Ahttps://([^/?]+)}, 1]
  end

  # Drawn for viewers and counted against the cap (sec 4.6): shown, not
  # hidden by staff, on a listed site, and not under a removal.
  #
  # @param removed [Set<String>] CreatorHarmonicRemoval.covering of the gallery's urls
  def counts?(removed)
    shown && !staff_hidden? && site_entry.present? && removed.exclude?(url)
  end

  # Why the owner sees this card in amber and viewers do not see it at all,
  # as a sentence naming the fix; nil for a counting card.
  def owner_notice(removed, number)
    if staff_hidden?
      "Harmonic #{number} was hidden by site staff#{": #{staff_hidden_reason}" if staff_hidden_reason.present?}. It is not shown on your page."
    elsif site_entry.nil?
      "Harmonic #{number}'s site was taken off the Tuner's list, so it is not shown and does not count. Its card comes back if the site does."
    elsif removed.include?(url)
      self.class.sentence(:link_removed, url: url.delete_prefix("https://"))
    end
  end
end
