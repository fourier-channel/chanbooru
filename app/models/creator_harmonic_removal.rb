# frozen_string_literal: true

# A link staff took down: a carve-out in the Tuner's site list that no gallery
# may carry again (CREATOR_TUNER.md sec 4.5, operator 2026-10-31: "a specific
# link being removed can be saved like any mod action, and added to a list of
# removals"). Written by an admin's hide of a harmonic, under that gallery's
# lock, and deleted by its unhide; the ModAction is the log.
#
# A link is covered when it is a removal or lies under one by whole path
# segments: civitai.com/user/bad covers civitai.com/user/bad/models, not
# civitai.com/user/badger. Matched lowercased, as stored.
class CreatorHarmonicRemoval < ApplicationRecord
  belongs_to :removed_by, class_name: "User"

  # The removals that would cover `url`: itself, itself without its query,
  # and each whole-segment cut of its path.
  def self.prefixes(url)
    url = url.downcase
    base = url.split("?", 2).first
    origin, path = base.match(%r{\A(https://[^/]*)(.*)\z}).captures
    segments = path.split("/").drop(1)
    cuts = segments.each_index.map { |i| [origin, *segments.first(i + 1)].join("/") }
    [url, base, origin, *cuts].uniq
  end

  # FNV-1a, 64 bits, of the link's bytes: how the owner's editor is handed
  # the removals (harmonic_model.js fingerprint), so the page carries no list
  # of what staff took down -- only what Save would answer for any one link.
  def self.fingerprint(url)
    url.bytes.reduce(0xcbf29ce484222325) { |hash, byte| ((hash ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF }.to_s(16).rjust(16, "0")
  end

  # @param urls [Array<String>] normalized links
  # @return [Set<String>] the ones a removal covers, one query
  def self.covering(urls)
    candidates = urls.index_with { |url| prefixes(url) }
    removed = where(url: candidates.values.flatten.uniq).pluck(:url).to_set
    candidates.select { |_, prefixes| prefixes.any? { |prefix| removed.include?(prefix) } }.keys.to_set
  end
end
