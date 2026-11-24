# frozen_string_literal: true

# Hosts this site must never contact, for any reason (operator ruling
# 2026-11-24: "Our website cannot ever contact baraag.net for any reason").
#
# The refusal itself is in Danbooru::Http::ApplicationClient#perform, the one
# place every outgoing request and every redirect hop passes, whichever client
# (external, internal, public_only or proxied) made it. Removing a site's
# extractor is not a refusal: Source::Extractor::Null fetches any URL it is
# given. The models refuse the same hosts up front, so that a new upload, post
# source, replacement or artist URL is turned away with a reason instead of
# being queued and failing.
#
# A constant and not a config setting: no local config can switch it off.
module Danbooru
  module RefusedHosts
    # Each host and every subdomain of it. This is the only place the host is
    # named outside its own test.
    HOSTS = %w[baraag.net].freeze

    # Characters a name lookup reads as a dot.
    DOTS = /[\u3002\uff0e\uff61]/

    # @param host [String, nil] a hostname
    # @return [Boolean] true if the host, or a parent domain of it, is refused
    def self.refused?(host)
      name = normalize(host)
      HOSTS.any? { |refused| name == refused || name.end_with?(".#{refused}") }
    end

    # @param url [String, Danbooru::URL, nil] a URL, with or without its scheme
    # @return [Boolean] true if the URL is on a refused host
    def self.refused_url?(url)
      return false if url.blank?

      parsed = Danbooru::URL.parse(url)
      parsed.present? && refused?(parsed.host)
    end

    # @return [String] what a person is told, and what they can do about it
    def self.message(host)
      "#{normalize(host)} is a refused site: this server never contacts it. Fix: use a link to another site"
    end

    # A hostname as a name lookup would read it: case, a trailing dot,
    # percent-encoding and Unicode forms of letters and dots do not matter.
    def self.normalize(host)
      name = host.to_s.dup.force_encoding("UTF-8").scrub("")
      name = Addressable::URI.unencode_component(name).dup.force_encoding("UTF-8").scrub("")
      name.unicode_normalize(:nfkc).gsub(DOTS, ".").downcase.strip.sub(/\.+\z/, "")
    end
    private_class_method :normalize

    # Validates that a URL attribute is not on a refused host, when it changes.
    # A row that already holds one can still be saved.
    class Validator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        return unless record.public_send(:"#{attribute}_changed?")

        if RefusedHosts.refused_url?(value)
          record.errors.add(attribute, "can't be used. #{RefusedHosts.message(Danbooru::URL.parse(value).host)}")
        end
      end
    end
  end
end
