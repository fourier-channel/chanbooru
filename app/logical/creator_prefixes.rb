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
#   - WHO SEES IT (operator, 2026-10-07: aichan_ posts hidden by default,
#     "admins only, for now"). `visible_to` per prefix: everyone (the
#     default), members (not signed-out visitors) or admins. A post carrying a
#     tag under a prefix hidden from a viewer is hidden from that viewer
#     everywhere Post.hidden_from / #hidden_from? reach -- every door, the
#     media gate included -- and so are those tag names. The posting accounts
#     (`editors`) always see them: they recognise duplicates and write tags
#     back to their own posts. Widening is an edit to this file, live.
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

  Entry = Struct.new(:prefix, :provenance, :target_kind, :target, :scope, :visible_to, keyword_init: true)

  VISIBILITIES = %w[everyone members admins].freeze
  DEFAULT_PATH = Rails.root.join("config/fourier/creator_prefixes.yml").to_s

  PREFIX_FORMAT = /\A[a-z0-9]{1,16}_\z/

  @mutex = Mutex.new
  @cache = nil
  @last_good = nil
  @names_mutex = Mutex.new
  @names = nil

  module_function

  def path
    ENV["FOURIER_CREATOR_PREFIXES"].presence || DEFAULT_PATH
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

      visible_to = (e["visible_to"].presence || "everyone").to_s
      unless VISIBILITIES.include?(visible_to)
        raise ConfigError, "#{file}: prefixes[#{i}] visible_to #{visible_to.inspect} must be one of #{VISIBILITIES.join(", ")}"
      end

      Entry.new(prefix: prefix, provenance: e["provenance"].to_s, target_kind: e["target_kind"].to_s,
                target: e["target"].to_s, scope: e["scope"].to_s, visible_to: visible_to)
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

  # The list for VISIBILITY, which never fails open. An unreadable live list
  # keeps the last one read, then the release's own copy, and says so in the
  # log: hiding must not switch off because a file broke. (The tag lock fails
  # the other way -- it refuses edits -- because refusing is safe there.)
  def visibility_config
    value = config
    @last_good = value
  rescue ConfigError => e
    Rails.logger.error("[creator_prefixes] #{e.message} -- visibility uses #{@last_good ? "the last list read" : "the release copy (#{DEFAULT_PATH})"}")
    @last_good || parse(File.read(DEFAULT_PATH), DEFAULT_PATH)
  end

  # Does `user` see posts under this entry's prefix?
  def sees?(entry, user)
    case entry.visible_to
    when "everyone" then true
    when "members" then user.present? && !user.is_anonymous?
    else user.present? && !user.is_anonymous? && (user.is_admin? || visibility_config[:editors].include?(user.name))
    end
  end

  # The entries whose posts are hidden from `user`.
  def hidden_prefixes_for(user)
    visibility_config[:entries].reject { |e| sees?(e, user) }
  end

  # What decides, for one viewer: the prefixes hidden from them, the creators
  # released from their prefix's default (CreatorTagRelease -- public by their
  # own tag from then on), and the creators they hold an approved claim on,
  # whose posts they always see.
  def hidden_context(user)
    prefixes = hidden_prefixes_for(user)
    return { prefixes: [], released: Set.new, owned: Set.new } if prefixes.empty?

    { prefixes: prefixes, released: CreatorTagRelease.released_names, owned: CreatorTagRelease.owned_names(user) }
  end

  # Is this tag under a prefix hidden from `user`, and not released or theirs?
  def hidden_for?(tag_name, user, ctx = hidden_context(user))
    name = tag_name.to_s
    return false if ctx[:released].include?(name) || ctx[:owned].include?(name)

    ctx[:prefixes].any? { |e| name.start_with?(e.prefix) && name.length > e.prefix.length }
  end

  # Every existing tag name under a prefix hidden from `user` -- what
  # Post.hidden_from and the tag index filter on. A new creator's tag is a new
  # tag row, so the cache is keyed on the newest tag id as well as the
  # prefixes: exact, never a timer.
  def hidden_tag_names_for(user)
    ctx = hidden_context(user)
    prefixes = ctx[:prefixes].map(&:prefix).sort
    return [] if prefixes.empty?

    key = [prefixes, Tag.maximum(:id)]
    names = @names_mutex.synchronize { @names[:value] if @names && @names[:key] == key }
    unless names
      names = prefixes.flat_map { |p| Tag.where("name LIKE ?", "#{Tag.sanitize_sql_like(p)}%").pluck(:name) }.freeze
      @names_mutex.synchronize { @names = { key: key, value: names } }
    end
    names.reject { |n| ctx[:released].include?(n) || ctx[:owned].include?(n) }
  end

  # The ids of every post carrying such a tag -- what post searches exclude.
  def hidden_post_ids_for(user)
    names = hidden_tag_names_for(user)
    return [] if names.empty?

    Post.where_array_includes_any("string_to_array(posts.tag_string, ' ')", names).order(:id).pluck(:id)
  end

  # Forget the cached list (tests).
  def reset!
    @mutex.synchronize { @cache = nil }
    @names_mutex.synchronize { @names = nil }
    @last_good = nil
  end
end
