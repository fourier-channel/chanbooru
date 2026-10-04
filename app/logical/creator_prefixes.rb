# frozen_string_literal: true

# THE CREATOR-PREFIX LIST: what each creator-tag prefix means, and the lock.
#
# Operator ruling 2026-10-04. Every post carries a creator tag whose prefix is
# its provenance (4chan_<name>, 41chan_<name>, aichan_<name>, ...). The list of
# those prefixes is CONFIG, not code: "adding or changing a prefix is a config
# change and not a rebuild." It does two jobs:
#
#   - THE LOCK. A tag carrying a listed prefix may be added to or removed from a
#     post only by an admin or by one of the listed editors (the posting
#     services). Any member could otherwise strip a post's creator or forge one,
#     and the claim rule (ArtistClaim) and every count by creator read tags.
#   - THE LOOKUP. Each entry names the provenance, the target and the scope, so
#     a prefix answers "where did this come from" exactly (/creator_prefixes).
#
# WHERE IT LIVES. FOURIER_CREATOR_PREFIXES names the file; production points it
# at a host directory mounted into the container, outside the read-only release,
# so an edit there is live. Unset, the repo's config/fourier/creator_prefixes.yml
# is used, which is what development and the tests read.
#
# LIVE. The file is re-read when its size, mtime or inode moves -- one stat per
# check, never a timer -- so an edit takes effect on the next tag edit with no
# restart. The inode is in the stamp because an editor that saves by rename
# leaves size and mtime looking plausible on a different file.
#
# FAILS LOUDLY. An unreadable or malformed list is never "no prefixes": that
# would switch the lock off silently. Load raises ConfigError naming the file
# and the fault; the post validation turns it into a refusal of that edit, so
# members cannot edit tags until it is fixed and nothing is unlocked meanwhile.
module CreatorPrefixes
  class ConfigError < StandardError; end

  Entry = Struct.new(:prefix, :provenance, :target_kind, :target, :scope, keyword_init: true)

  PREFIX_FORMAT = /\A[a-z0-9]{1,16}_\z/

  @mutex = Mutex.new
  @cache = nil

  module_function

  def path
    ENV["FOURIER_CREATOR_PREFIXES"].presence || Rails.root.join("config/fourier/creator_prefixes.yml").to_s
  end

  # { entries: [Entry], editors: [String] }, re-read when the file changed.
  def config
    file = path
    stat = begin
      File.stat(file)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise ConfigError, "the creator-prefix list #{file} cannot be read (#{e.class.name.demodulize}). " \
                         "Fix: restore it (the canon copy is fourier-basis ops/hetzner/danbooru/creator_prefixes.yml)"
    end
    stamp = [file, stat.size, stat.mtime.to_f, stat.ino]
    @mutex.synchronize do
      return @cache[:value] if @cache && @cache[:stamp] == stamp

      value = parse(File.read(file), file)
      @cache = { stamp: stamp, value: value }
      value
    end
  end

  def parse(text, file)
    doc = YAML.safe_load(text) || {}
    raise ConfigError, "#{file} is not a mapping with `prefixes:` and `editors:`" unless doc.is_a?(Hash)

    entries = Array(doc["prefixes"]).map.with_index do |e, i|
      raise ConfigError, "#{file}: prefixes[#{i}] is not a mapping" unless e.is_a?(Hash)

      prefix = e["prefix"].to_s
      unless prefix.match?(PREFIX_FORMAT)
        raise ConfigError, "#{file}: prefixes[#{i}] prefix #{prefix.inspect} must be lowercase letters or digits ending in _ (e.g. aichan_)"
      end

      Entry.new(prefix: prefix, provenance: e["provenance"].to_s, target_kind: e["target_kind"].to_s,
                target: e["target"].to_s, scope: e["scope"].to_s)
    end
    dupes = entries.map(&:prefix).tally.select { |_, n| n > 1 }.keys
    raise ConfigError, "#{file}: prefix listed twice: #{dupes.join(", ")}" if dupes.any?

    editors = Array(doc["editors"]).map(&:to_s)
    { entries: entries.freeze, editors: editors.freeze }
  rescue Psych::Exception => e
    raise ConfigError, "#{file} is not valid YAML: #{e.message}"
  end

  def entries = config[:entries]

  # The entry whose prefix this tag carries, or nil.
  def lookup(tag_name)
    name = tag_name.to_s
    entries.find { |e| name.start_with?(e.prefix) && name.length > e.prefix.length }
  end

  def locked?(tag_name) = !lookup(tag_name).nil?

  # May this user add or remove a locked tag? Admins and the listed editors.
  def editor?(user)
    return false if user.nil? || user.is_anonymous?
    return true if user.is_admin?

    config[:editors].include?(user.name)
  end

  # Forget the cached list (tests).
  def reset!
    @mutex.synchronize { @cache = nil }
  end
end
