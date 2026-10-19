# frozen_string_literal: true

# Sidecar provenance for a post's tags (the redesigned tag buckets). Rides
# alongside Danbooru's denormalised tag_string without touching core tables.
# One row per (post, tag). `source` is a bitflag so a tag can be several sources
# at once (creator AND auto => the "both" bucket). Also carries creator
# attribution and the created_at used for the grace-period edit lock.
class FourierTagSource < ApplicationRecord
  belongs_to :post

  # source bitflags
  CREATOR = 1
  AUTO    = 2
  HUMAN   = 4
  META    = 8
  # WHICH MODEL (operator ruling 2026-09-20: "the lamp is visible provenance").
  # Two taggers run on the same images; these bits record which of them put a
  # tag here so a reader can see where they agree. OR-ed onto an AUTO or META
  # row. A row with AUTO and neither bit predates this and is spectrum -- the
  # tunnel has only ever called spectrum, and sampling's own record says an
  # absent tagger means spectrum.
  SPECTRUM = 16
  HYDRA    = 32

  # status
  APPROVED = 0
  PENDING  = 1

  scope :approved,         -> { where(status: APPROVED) }
  scope :pending,          -> { where(status: PENDING) }
  scope :meta,             -> { where("source & ? > 0", META) }
  scope :content,          -> { where("source & ? = 0", META) }
  scope :publicly_visible, -> { where(public: true) }

  def creator? = source & CREATOR > 0
  def auto?    = source & AUTO > 0
  def spectrum? = source & SPECTRUM > 0
  def hydra?    = source & HYDRA > 0
  def human?   = source & HUMAN > 0
  def meta?    = source & META > 0
  def both?    = creator? && auto?
  def pending? = status == PENDING

  # The visual bucket for the redesigned tag UI.
  def bucket
    return :pending if pending?
    return :meta if meta?
    return :both if both?
    return :creator if creator?

    :auto
  end

  # Upsert provenance for a post from a {creator, auto, both, meta, pending}
  # partition (the shape sampling and tunnel send). Idempotent per (post, tag).
  # Creator-ONLY tags are
  # private by default (prompt-derived, may leak); everything else is public.
  #
  # NAMES ARE RESOLVED FIRST (FourierTagResolver): aliases, and a prompt's
  # "hilda" to the booru's hilda_(pokemon). Then the partition is RE-DERIVED,
  # because resolution can make a creator name and an auto name the same
  # name -- and the old rule, first list wins, would have filed that tag as
  # creator-only and PRIVATE, hiding a tag the autotagger had put on the
  # public post. After resolution a name in both creator and auto is `both`.
  #
  # @return [Hash{String => String}] each name sent as an original character
  #   (`oc`) that was not declared, with why and what to do; {} when none
  def self.record_partition!(post, sources, user, replace_creator: false)
    now = Time.zone.now
    fetch = ->(k) { Array(sources[k.to_s] || sources[k.to_sym]).map(&:to_s).reject(&:blank?) }
    lists = %i[both creator auto meta pending spectrum hydra].index_with { |k| fetch.call(k) }
    resolved = FourierTagResolver.resolve(lists.values.flatten)
    lists = lists.transform_values { |names| names.map { |n| resolved.fetch(Tag.normalize_name(n), n) }.uniq }
    # Which model reported each tag. Resolved through the same aliases as the
    # buckets above, or a renamed tag would lose its lamp.
    spectrum = lists[:spectrum].to_set
    hydra = lists[:hydra].to_set
    model_bits = ->(t) { (spectrum.include?(t) ? SPECTRUM : 0) | (hydra.include?(t) ? HYDRA : 0) }
    # ORIGINAL CHARACTERS, from the hub's `oc` list -- the list a creator
    # makes public by putting a name in it. Never read from the prompt's
    # creator lists: those are the creator's alone (FourierCreatorPrivacy). A
    # name in `oc` is DECLARED -- put on the post, public, filed as a
    # character (declare_original_characters!) -- when it is:
    #
    #   <name>_(<the poster's own localpart>)  (operator ruling 2026-10-11),
    #       the poster being the account RECORDED as this post's creator
    #       (FourierPostCreator) on this homeserver -- `user` is the posting
    #       bot, never the creator -- and the name passing
    #       original_character_refusal. Refused by name otherwise, in the
    #       return value.
    #   <name>_(<anyone>) that is already an established original character
    #       (a character tag implying `original`), whoever posted it
    #       (2026-10-12). Declaring confers no ownership.
    #   one of the 2026-09-19 shapes (LEGACY_ORIGINAL_CHARACTER), whoever
    #       posted it (operator, 2026-10-12: "continue to accept the
    #       pre-existing format but prepare for them to be changed manually for
    #       the first few. so oc_kayla will, for example, become the
    #       kayla_(selphdestruct) tag itself"): AS ITSELF while no alias moves
    #       it, and as the alias's consequent once one does. NEVER read from
    #       the poster -- "Many of these characters belong to other creators,
    #       I'll just be the first one to post them."
    #
    # OFFERED OR DECLARED, told apart by the lists alone (the contract with
    # fourier-tunnel's prompt-tags.js). A qualified name in `oc` that is ALSO
    # in the creator lists (creator or both, as sent, before resolution) is
    # OFFERED: the tunnel sends every qualified prompt term that is not the
    # poster's own -- every one, where it knows no poster -- both ways. An
    # offer is declared when it is the recorded creator's own or an
    # established original character, and otherwise says NOTHING: not
    # declared, not refused (saber_(fate) is not an error), the private
    # creator row it arrived as -- on a post with no recorded creator too.
    # A name in `oc` ALONE is the tunnel's "the poster's own", in no other
    # list: one the booru does not declare is refused by name, never dropped
    # in silence. Refusals are keyed by the name SENT.
    sent = fetch.call(:oc).map { |n| Tag.normalize_name(n) }.uniq
    legacy = sent.select { |name| legacy_original_character(name) }
    qualified = sent.grep(ORIGINAL_CHARACTER)
    offered = qualified & (fetch.call(:creator) + fetch.call(:both)).map { |n| Tag.normalize_name(n) }
    poster = FourierPostCreator.where(post_id: post.id).pick(:mxid) if (sent - legacy).any?
    home = Danbooru.config.fourier_matrix_server_name
    localpart = ArtistClaim.localpart(poster)
    localpart = nil unless poster.to_s.casecmp?("@#{localpart}:#{home}")
    moved = legacy.empty? ? {} : TagAlias.active.where(antecedent_name: legacy).pluck(:antecedent_name, :consequent_name).to_h
    own = localpart ? qualified.select { |name| ORIGINAL_CHARACTER.match(name)[2].casecmp?(localpart) } : []
    established = (qualified - own).empty? ? [] : TagImplication.tags_implied_to([CharacterClaim::ORIGINAL]).where(name: qualified - own, category: TagCategory::CHARACTER).pluck(:name)
    silent = offered - own - established
    as_legacy = legacy.map { |name| moved.fetch(name, name) }
    refused = (sent - legacy - as_legacy - established - silent).index_with { |name| original_character_refusal(name, post, poster, localpart) }.compact
    oc = (as_legacy + (own - refused.keys) + established).uniq
    refused.each_value { |why| Rails.logger.warn("[tag-hub] original character not declared: #{why}") }

    creator = (lists[:creator] + lists[:both]).uniq - oc
    auto = (lists[:auto] + lists[:both]).uniq
    both = creator & auto
    rows = []
    add = ->(tags, source, status, pub) { tags.each { |t| rows << { post_id: post.id, tag: t, source: source | model_bits.call(t), status: status, public: pub, added_by: user&.id, created_at: now } } }
    add.call(both,           CREATOR | AUTO, APPROVED, true)
    add.call(oc,             CREATOR,        APPROVED, true)
    add.call(creator - both, CREATOR,        APPROVED, false)
    add.call(auto - both,    AUTO,           APPROVED, true)
    add.call(lists[:meta],   META,           APPROVED, true)
    add.call(lists[:pending], HUMAN,         PENDING,  true)
    declare_original_characters!(post, oc, user, refile: oc - moved.values) if oc.any?
    transaction do
      # A re-read of the bytes replaces the previous read: every row that
      # carries the creator bit goes, `both` included -- a tag still in both
      # lists comes straight back as both, one now only the autotagger's
      # comes back as auto, and one the prompt no longer yields is gone.
      where(post_id: post.id).where("source & ? > 0", CREATOR).delete_all if replace_creator
      upsert_all(rows.uniq { |r| r[:tag] }, unique_by: %i[post_id tag]) if rows.any?
    end
    refused
  end

  # Posts per call to record_models!, and to the route that serves it.
  MAX_MODEL_POSTS = 100

  # WHICH MODEL REPORTED EACH TAG, for posts that already have provenance.
  #
  # record_partition! is the write at post time, and it re-derives buckets:
  # the wrong tool for saying afterwards "hydra saw this too". The retag
  # timer in fourier-sampling adds hydra's tags to existing posts, and with
  # nothing but record_partition! to call it filed every one with no model
  # bit -- and 22.4M rows predate the bits entirely, which the lamp reads as
  # spectrum. This is the other write: it ONLY ever ORs model bits in.
  #
  # For each tag named in either list, after the same name resolution
  # record_partition! uses:
  #
  #   a row exists              source |= the bits (whatever the row is)
  #   no row, tag on the post   insert AUTO | bits, public, approved
  #   neither                   skip
  #
  # Never clears a bit, never touches bucket bits, public, status, added_by
  # or created_at, and never fans out: the lamp is not part of the public
  # projection.
  #
  # NEVER A PRIVATE ROW (round-two finding 5). This route is builder+, which
  # is every moderator and admin, and the creator-only ruling (2026-09-29)
  # excludes every one of them. Answering "updated" for a creator's private
  # tag and "skipped" for a wrong guess confirmed, one guess per call, which
  # prompt tags a creator's post carries -- and rewrote the private row's bits
  # as it did. So the OR update is scoped to public rows: a private row is an
  # existing row that is never written, and its tag counts as skipped exactly
  # like a tag the post does not have. It is never inserted over either --
  # the insert only fills tags with no row at all, and one written between
  # the read and the insert meets ON CONFLICT and then the same public-only
  # update. A creator's private tag that a model also found keeps no lamp.
  #
  # Every (post, tag) asked about lands in exactly one count: `updated` if its
  # bits changed, `inserted` if its row is new, `skipped` otherwise -- not on
  # the post, or already carrying those bits. So a second identical call
  # reports everything as skipped, which is what idempotent looks like.
  #
  # Race-safe without a lock. The poster writes this table continuously: the
  # update is one conditional statement, and an insert that meets a row
  # written since the read is ON CONFLICT DO NOTHING, then OR'd like any
  # other existing row.
  #
  # @param entries [Array<Hash>] { post_id:, spectrum: [names], hydra: [names] }
  # @return [Hash] { updated:, inserted:, skipped:, missing_posts: [ids] }
  def self.record_models!(entries, user)
    wanted = entries.group_by { |e| e[:post_id] }.transform_values do |es|
      %i[spectrum hydra].index_with { |k| es.flat_map { |e| Array(e[k]) } }
    end
    resolved = FourierTagResolver.resolve(wanted.values.flat_map { |l| l[:spectrum] + l[:hydra] })
    resolve = ->(names) { names.map(&:to_s).compact_blank.to_set { |n| resolved.fetch(Tag.normalize_name(n), n) } }

    # A flagged post the caller may not see (TagQuarantine: another bot's
    # upload) is a missing post here, as on every other door.
    tag_strings = Post.where(id: wanted.keys).where.not(id: TagQuarantine.hidden_post_ids_for(user)).pluck(:id, :tag_string).to_h
    result = { updated: 0, inserted: 0, skipped: 0, missing_posts: wanted.keys - tag_strings.keys }
    now = Time.zone.now

    tag_strings.each do |post_id, tag_string|
      spectrum = resolve.call(wanted[post_id][:spectrum])
      hydra = resolve.call(wanted[post_id][:hydra])
      bits = (spectrum | hydra).index_with { |t| (spectrum.include?(t) ? SPECTRUM : 0) | (hydra.include?(t) ? HYDRA : 0) }
      next if bits.empty?

      existing = where(post_id: post_id, tag: bits.keys).pluck(:tag)
      on_post = tag_string.to_s.split.to_set
      absent = bits.keys - existing
      fresh = absent.select { |t| on_post.include?(t) }
      result[:skipped] += absent.size - fresh.size

      if fresh.any?
        rows = fresh.map { |t| { post_id: post_id, tag: t, source: AUTO | bits[t], status: APPROVED, public: true, added_by: user&.id, created_at: now } }
        inserted = insert_all(rows, unique_by: %i[post_id tag], returning: %w[tag]).rows.flatten
        result[:inserted] += inserted.size
        existing += fresh - inserted # lost the race to another writer: OR into its row below
      end

      existing.group_by { |t| bits[t] }.each do |b, tags|
        changed = where(post_id: post_id, tag: tags, public: true).where("source & ? <> ?", b, b).update_all(["source = source | ?", b])
        result[:updated] += changed
        result[:skipped] += tags.size - changed
      end
    end
    result
  end

  # A TAG MOVE MOVES ITS PROVENANCE TOO.
  #
  # Aliasing anus -> butthole moved every post's tag_string and left 35,396
  # sidecar rows saying "anus" (operator, 2026-09-19: "'Anus' is still being
  # tagged on images after being aliased to 'butthole'"). The post page draws
  # its pills from HERE, not from tag_string, so the old name kept appearing
  # on pictures whose tags no longer contained it -- and the hype list, which
  # names only the canonical "butthole", could not match it either.
  #
  # Called from TagMover, so every alias, every rename and every manual move
  # carries provenance with it. Aliasing at the WRITE path
  # (FourierTagResolver) only ever fixed rows written after the alias existed;
  # this is the half that fixes the ones written before.
  #
  # A post that already carries the new name keeps ONE row: the source bits
  # are OR'd (a tag that was the creator's under one name and the tagger's
  # under the other is genuinely both), the earlier created_at wins because it
  # is what the grace-period edit lock reads, approved beats pending because
  # the tag is on the post either way, and public beats private for the reason
  # record_partition! already writes `both` as public.
  #
  # AN UPSERT, NOT A RENAME, because the table is written while this runs.
  # The poster adds rows under the new name continuously. A rename guarded by
  # "does a counterpart exist" -- even with the guard inside the UPDATE -- reads
  # its subquery at statement start and meets the unique index at write time,
  # so a row committed in between kills the whole move (seen twice against
  # production, 2026-09-19). An upsert asks the index itself and merges what it
  # finds there, which is the only form that cannot race.
  #
  # @return [Integer] rows carried over
  def self.move_tag!(old_name, new_name, batch_size: 1000)
    old_name = Tag.normalize_name(old_name.to_s)
    new_name = Tag.normalize_name(new_name.to_s)
    return 0 if old_name.blank? || new_name.blank? || old_name == new_name

    merge = Arel.sql(<<~SQL.squish)
      source = fourier_tag_sources.source | excluded.source,
      status = LEAST(fourier_tag_sources.status, excluded.status),
      public = fourier_tag_sources.public OR excluded.public,
      created_at = LEAST(fourier_tag_sources.created_at, excluded.created_at)
    SQL

    moved = 0
    loop do
      rows = where(tag: old_name).limit(batch_size)
                                 .pluck(:id, :post_id, :source, :status, :public, :added_by, :created_at)
      break if rows.empty?
      transaction do
        upsert_all(
          rows.map do |(_id, post_id, source, status, pub, added_by, created_at)|
            { post_id: post_id, tag: new_name, source: source, status: status,
              public: pub, added_by: added_by, created_at: created_at }
          end,
          unique_by: %i[post_id tag], on_duplicate: merge,
        )
        moved += where(id: rows.map(&:first)).delete_all
      end
    end
    moved
  end

  # An original character's tag: <name>_(<creator>), a name and then, in
  # brackets, the Matrix localpart of the creator whose character it is
  # (operator ruling 2026-10-11: "<name>_(<creator>) is THE OC tag"). Group 1
  # is the name, group 2 the creator. Who may declare one at post time is
  # original_character_refusal's to decide (the post's recorded creator, by
  # their own name), and who may claim one is CharacterClaim's (the gallery
  # of that name). It replaced the oc_<name> shapes of 2026-09-19, which
  # recorded no owner and gave every creator the same name
  # (LEGACY_ORIGINAL_CHARACTER).
  ORIGINAL_CHARACTER = /\A([a-z0-9][^()]*)_\(([^()]+)\)\z/

  # The four shapes the 2026-09-19 rule accepted, which recorded no owner:
  # oc_<name>, character_oc_<name>, <name>_oc, <name>_character_oc. Every
  # pre-existing OC image carries one, so they are still accepted, and their
  # owners are learned only from the operator, one tag at a time (2026-10-12:
  # the poster is not the creator). Until a tag is moved, a name in this shape
  # is declared as itself (record_partition!); the operator moves it onto
  # <name>_(<creator>) -- script/fourier_original_characters.rb --map, or an
  # alias or rename request -- and the move gives <creator> the character
  # (CharacterClaim.take_up_on_move!). Group 1 or 2 is <name>. The same
  # pattern as the old rule's
  # /\A(?:(?:character_)?oc_[a-z0-9].*|.*[a-z0-9]_(?:character_)?oc)\z/,
  # with the suffix forms' name taken shortest-first so moss_character_oc is
  # moss and not moss_character.
  LEGACY_ORIGINAL_CHARACTER = /\A(?:character_)?oc_([a-z0-9].*)\z|\A(.*?[a-z0-9])_(?:character_)?oc\z/

  # <name> from a name in one of the old shapes, nil for any other name. A
  # name already ending in a creator in brackets is that creator's, whatever
  # it starts with, so it is never read as an old shape.
  def self.legacy_original_character(name)
    return nil if ORIGINAL_CHARACTER.match?(name)

    match = LEGACY_ORIGINAL_CHARACTER.match(name)
    match && (match[1] || match[2])
  end

  # Why `name`, sent in the hub's `oc` list for `post`, is not declared; nil
  # when it is. The creator's own name in brackets (CharacterClaim's name
  # rule: no creator prefix, no qualifier the booru reserves), and a tag that
  # can be filed as a character without taking anything from anyone: absent,
  # already a character, or general and EMPTY (or general and the poster's by
  # a standing claim). A general tag with posts is never re-filed here -- a
  # creator whose name is a common qualifier (`food`, say) would otherwise
  # re-file every <x>_(food) -- and the remedy is a claim, which an admin
  # reviews. One tag lookup per
  # name, and one claim lookup for a general tag with posts.
  def self.original_character_refusal(name, post, poster, localpart)
    match = ORIGINAL_CHARACTER.match(name)
    base = match ? match[1] : name
    home = Danbooru.config.fourier_matrix_server_name
    if match.nil?
      return "#{name} is not an original character's name: name it #{base}_(#{localpart || "<creator>"}), " \
             "the character's name then the creator's own Matrix name in brackets"
    elsif poster.nil?
      return "post ##{post.id} has no recorded creator, so #{name} was not declared under anyone's name. Fix: record who made it " \
             "(POST /fourier/posts/#{post.id}/creator.json), then send the tags again"
    elsif localpart.nil?
      return "#{poster} is not an account on #{home}: only a #{home} account's own name in brackets declares an original character, so #{name} was not declared"
    elsif !match[2].casecmp?(localpart)
      return "#{name} names #{match[2]}, but post ##{post.id} was made by #{poster}: only the poster's own name declares an original character. Name it #{base}_(#{localpart})"
    end

    reason = CharacterClaim.name_refusal(name, localpart, CreatorPrefixes.entries, fix: "name it")
    return reason if reason

    tag = Tag.find_by_name(name)
    if tag && !(tag.general? || tag.character?)
      "#{name} is filed as #{tag.category_name.downcase}: ask an admin to re-file it as a character, then send the tags again"
    elsif tag&.general? && tag.post_count.positive? && CharacterClaim.standing_on([name]).none? { |claim| claim.slug.casecmp?(localpart) }
      "#{name} is already a general tag on #{tag.post_count} #{"post".pluralize(tag.post_count)}, so it is not re-filed as a character at post time: " \
        "claim it from your creator page (an admin reviews a name that has history), then send the tags again"
    end
  rescue CreatorPrefixes::ConfigError => e
    # Fork: words only. What is wrong with the list (a path on the server,
    # an errno, the parser's words, the fix's command) goes to the log, and
    # without the name, which may be a private prompt term: this sentence is
    # original_characters_not_declared, which the posting bot relays
    # (technetium-81, 2026-10-19).
    Rails.logger.error("original character on post ##{post.id}: not checked, the creator-prefix list is broken: #{e.message}")
    "the creator-prefix list is broken, so #{name} cannot be checked and was not declared; the server log says what is wrong. " \
      "The site owner fixes the list, then send the tags again"
  end

  # An original character is DECLARED, not merely recorded: the name goes on
  # the post (public, so it is searchable and lands on the character shelf)
  # and each name in `refile` that is a general tag is filed under the
  # character category. Those are the poster's own names, which
  # original_character_refusal passed (so an empty general tag, or the
  # poster's own by a claim), established characters (already characters),
  # and legacy names declared as themselves (the 2026-09-19 rule, which filed
  # them so) -- never an alias's consequent, whose category is whoever made
  # the alias's: nobody's artist, copyright or well-used general tag is
  # re-filed because a name matched.
  def self.declare_original_characters!(post, names, user, refile:)
    missing = names - post.tag_array
    if missing.any?
      CurrentUser.scoped(user || User.system) do
        post.add_tag(*missing)
        post.save!
      end
    end
    CurrentUser.scoped(user || User.system) do
      refile.each do |name|
        tag = Tag.find_or_create_by_name(name)
        # A tag is versioned and its version needs an updater; the hub's own
        # API user is the honest one, since it is the hub declaring this.
        tag.update!(category: TagCategory::CHARACTER, updater: user || User.system) if tag.category == TagCategory::GENERAL
      end
    end
  end

  # Group a relation of rows into { creator, auto, both, meta, pending } tag lists.
  def self.buckets_for(rows)
    out = { creator: [], auto: [], both: [], meta: [], pending: [] }
    rows.each { |r| out[r.bucket] << r.tag }
    out.transform_values(&:uniq)
  end

  # The lamps, in the SAME shape but a hash of its own.
  #
  # These rode inside buckets_for's return value for one evening and took the
  # post page down with a TypeError: every consumer of that hash treats every
  # value as a list of tag names -- `buckets.values.flatten` fed a Hash to
  # Cache.hash, and the banishment filter's `names.reject` silently rewrote a
  # Hash as one. A new key in a hash whose values are uniform is not a new key,
  # it is a new SHAPE, and the callers were right to assume the old one. So the
  # two travel separately in Ruby and are joined only where they are serialised.
  def self.lamps_for(rows)
    out = { spectrum: [], hydra: [], both: [], manual: [] }
    rows.each { |r| out[r.lamp] << r.tag }
    out.transform_values(&:uniq)
  end

  # THE LAMP: which model put this tag here, or a person. The dot on the pill.
  #
  #   both      spectrum AND hydra reported it -- the swirl
  #   hydra     hydra only -- green appears only where hydra has been
  #   spectrum  spectrum only, OR a model row from before the bits existed
  #   manual    nobody's model: a creator's prompt or a human edit
  #
  # A creator tag the autotagger also found lights the MODEL's lamp: the
  # question the lamp answers is which model saw it, and one did. White is for
  # a tag no model produced at all.
  def lamp = self.class.lamp_of(source)

  # The same rule for a bare source value -- the gallery's bit_or over a page,
  # which has no row behind it.
  def self.lamp_of(source)
    return :both if source & SPECTRUM > 0 && source & HYDRA > 0
    return :hydra if source & HYDRA > 0
    return :spectrum if source & (SPECTRUM | AUTO | META) > 0

    :manual
  end

  # Can `viewer`, on `request`, see this post's PRIVATE (creator-only) tags?
  # The post's creator, and nobody else -- FourierCreatorPrivacy, the one rule
  # for these tags and for generation data alike (operator ruling 2026-09-29:
  # "It's essentially the same data"). Not a moderator, not an admin, not the
  # account attributed on the rows (added_by is the posting bot for every
  # tunnel post), and not the holder of any TagGrant: a grant is a
  # moderator's row, and the creator decides.
  #
  # `request` carries the viewer's verified Matrix identity, which is how a
  # tunnel post's creator is recognised. It defaults to the current request;
  # outside one (a job, a console) no Matrix identity matches.
  def self.private_visible_to?(post, viewer, request: CurrentUser.request)
    FourierCreatorPrivacy.visible_to?(post, viewer, request)
  end

  # Tag buckets visible to `viewer` (identity-gated read): public rows always,
  # private rows only if the viewer is the creator (private_visible_to?).
  #
  # Tags with NO row here land in :unsourced rather than vanishing. This table
  # is a sidecar, not the tag list -- rows are written by exactly one endpoint
  # (POST /posts/:id/tag_sources.json) and nothing hooks Post's own tag changes,
  # so every tag added by any other route had no row and was silently dropped
  # from the only view that reads this: a moderator's hand edit, Danbooru's own
  # upload-time tags, and troll_jail, which fourier-sampling applies with a
  # plain tag_string PUT. The jail tag being invisible on 38 posts is what
  # surfaced it. blacklist_tags_for already treats an absent row as "nothing to
  # withhold"; this method disagreeing with it was the defect.
  #
  # `known` is plucked from ALL rows, BEFORE the visibility filter. Taking it
  # from the filtered set instead would hand a private creator tag back to the
  # very viewer the filter just took it from, through the fallback -- the tag
  # would have no VISIBLE row and so would read as unsourced. The privacy gate
  # is the reason this table exists; the fallback must not open a second door.
  #
  # ONLY ROWS FOR TAGS THE POST STILL HAS (2026-09-20). The sidecar is written
  # at post time and by TagMover, and nothing hooks Post's own tag changes --
  # the paragraph above says so about ADDED tags. The same gap runs the other
  # way: a tag REMOVED from tag_string kept its row, and this method drew the
  # row, so the pill never left the page. Measured on production: a removal
  # from Technetium landed in post_versions and in posts.tag_string within
  # the second, and the post page went on showing the tag because its row was
  # still here. Adds appeared (through :unsourced) and removes never did --
  # the exact asymmetry reported. 8,595 such orphan rows across 273 posts in
  # the seven days before this was found.
  #
  # Intersecting here fixes the page, the tag_sources.json read Technetium
  # uses for provenance, and blacklist_data, all at read time and with no
  # backfill. The privacy argument above survives it unchanged: `known` is
  # still taken before the visibility filter, only now from the rows for tags
  # the post actually carries. Pruning the orphans themselves is a separate,
  # write-side task and is not attempted here.
  def self.for_viewer(post, viewer, request: CurrentUser.request)
    buckets, = buckets_and_lamps_for(post, viewer, request: request)
    buckets
  end

  # Buckets AND lamps from one pass over one query, for the caller that needs
  # both -- the post page. Returned as a pair rather than one merged hash for
  # the reason lamps_for gives.
  #
  # A CREATOR'S PRIVATE ROWS ARE NOT INTERSECTED WITH tag_string (round-two
  # finding 1). The intersection above is for PUBLIC rows, whose tags live in
  # tag_string and can be removed from it. A private creator tag never enters
  # tag_string at all: fourier-tunnel has kept creator-only tags out of it
  # since 37270f5 (2026-08-06), so the row IS the tag, and intersecting it
  # away handed every real creator an empty creator bucket while
  # private_visible_to? said yes. So the creator gets every private row the
  # post has, in tag_string or not; everyone else gets none of them, and no
  # private row is even read for them.
  def self.buckets_and_lamps_for(post, viewer, request: CurrentUser.request)
    current = post.tag_string.to_s.split
    scoped = where(post_id: post.id)
    rows = scoped.where(tag: current)
    known = rows.pluck(:tag)
    rows = private_visible_to?(post, viewer, request: request) ? rows.or(scoped.where(public: false)) : rows.publicly_visible
    # A quarantined name the viewer may not be shown (TagQuarantine) -- on a
    # visible post only a creator's private row can carry one, its tag being
    # outside tag_string, so the post is not hidden by it.
    hidden = TagQuarantine.hidden_names_for(viewer)
    rows = rows.where.not(tag: hidden) if hidden.any?
    rows = rows.to_a
    unsourced = current - known - hidden
    # An unsourced tag has no row, so no model claimed it -- which is exactly
    # what a white lamp says. A tag added by hand from Matrix lands here (the
    # Technetium write goes through Post's own tag edit, and nothing hooks that
    # to write a sidecar row), and the operator ruled 2026-09-20 that it reads
    # as what it is: a general tag, orange, with a white lamp.
    lamps = lamps_for(rows)
    lamps[:manual] = (lamps[:manual] + unsourced).uniq
    [buckets_for(rows).merge(unsourced: unsourced), lamps]
  end

  # ONE READ, EVERYTHING A SURFACE NEEDS TO DRAW A TAG POOL.
  #
  # Technetium used to ask for this in two requests -- the post for categories
  # and rating, this sidecar for buckets and lamps -- and paid two round trips
  # per image on screen to answer one question. They already shared a limiter
  # slot and produced one render, so this is not a rendering fix; it is half
  # the requests.
  #
  # TAG_STRING HERE IS THE VIEWER'S, NOT THE POST'S. That is the part worth
  # being careful about. Danbooru's own /posts/:id.json hands out the
  # denormalised tag_string, which still contains the private creator tags
  # this class exists to withhold -- so a client that read it for a write's
  # old_tag_string was holding them, undisplayed but present. What goes out
  # here is the union of the buckets this viewer may see, which is exactly
  # what the booru's own Modulation page sends as old_tag_string, and for the
  # same reason: Danbooru applies only the DIFFERENCE between the two strings,
  # so a tag in neither is untouched. Private tags stay put and unmentioned.
  #
  # For the creator that union includes their private tags, which are not in
  # the post's tag_string. Sent back as old_tag_string they are harmless for
  # the same reason: a tag in both strings is no difference, so an edit never
  # ADDS a private tag to tag_string; one the creator drops from the new
  # string is "removed" from a tag_string that does not carry it.
  #
  # Categories are intersected against that same visible set, so a category
  # cannot smuggle back a name the buckets withheld.
  def self.live_read(post, viewer, request: CurrentUser.request)
    buckets, lamp = buckets_and_lamps_for(post, viewer, request: request)
    visible = buckets.values.flatten.uniq
    cats = Tag.categories_for(visible)
    names = TagCategory.reverse_mapping
    categories = Hash.new { |h, k| h[k] = [] }
    visible.each { |n| categories[names.fetch(cats[n], "general")] << n }
    buckets.merge(
      lamp: lamp,
      rating: post.rating,
      tag_string: visible.join(" "),
      categories: categories,
    )
  end

  # The tags that may be published into the DOM for `viewer`, per post, in one
  # query for a whole page.
  #
  # Blacklists are applied CLIENT-side: the rules match against a data-tags
  # attribute on each post element. That makes "which tags may this viewer see"
  # a question that has to be answered before rendering, in bulk -- and it makes
  # post.tag_string the wrong answer, because the denormalised tag_string this
  # table rides alongside still contains the private creator tags this class
  # exists to withhold. Publishing it would put prompt-derived tags in the page
  # source of the default view of every gallery.
  #
  # The consequence is deliberate: a viewer's blacklist cannot match a tag that
  # viewer is not allowed to see. That is the correct trade -- you cannot filter
  # on what you cannot be shown, and the alternative is disclosing it.
  #
  # Posts with no rows here are unaffected: nothing about them is private, so
  # they keep their full tag string and blacklist exactly as they did before.
  #
  # Who may see a post's private rows is private_visible_to?'s rule, asked for
  # the whole page at once (FourierCreatorPrivacy.readable_post_ids) and only
  # for the posts that have private rows at all.
  #
  # The creator's own private tags are ADDED for the creator, as
  # buckets_and_lamps_for draws them: they are not in tag_string (see there),
  # so "the tag string, unfiltered" would withhold them from the one viewer
  # who may see them. Everyone else gets tag_string less any private tag it
  # still carries -- the posts from before 37270f5 that have one there.
  def self.blacklist_tags_for(posts, viewer, request: CurrentUser.request)
    posts = Array(posts)
    return {} if posts.empty?

    by_post = where(post_id: posts.map(&:id), public: false).pluck(:post_id, :tag).group_by(&:first)
    readable = FourierCreatorPrivacy.readable_post_ids(posts.select { |post| by_post.key?(post.id) }, viewer, request)
    # A creator's private quarantined name stays out of the page (see
    # buckets_and_lamps_for).
    hidden = readable.any? ? TagQuarantine.hidden_names_for(viewer) : []

    posts.index_with do |post|
      tags = post.tag_string.to_s.split
      rows = by_post[post.id]
      next tags if rows.blank?

      private_tags = rows.map { |(_, tag)| tag }
      readable.include?(post.id) ? (tags | private_tags) - hidden : tags - private_tags
    end
  end

  # The PUBLIC-SAFE projection for the Matrix state event / anonymous views.
  # Private tags and unapproved suggestions are omitted -- nothing sensitive
  # ever leaves the gated store.
  def self.matrix_projection(post)
    # Same intersection as for_viewer, for the same reason: a row whose tag has
    # left the post is not provenance for anything.
    #
    # And never a quarantined name (TagQuarantine: flagged or banished), for
    # every caller, the posting bots included: Matrix room state is read by
    # every member of the room, so a name the booru hides must not travel
    # there in tags, sources or lamps (operator rulings 2026-10-12).
    quarantined = TagQuarantine.flagged_names | TagQuarantine.banished_names
    rows = where(post_id: post.id, public: true, status: APPROVED, tag: post.tag_string.to_s.split - quarantined.to_a).to_a
    b = buckets_for(rows)
    { tags: (b[:creator] + b[:auto] + b[:both] + b[:meta]).uniq, sources: b.slice(:creator, :auto, :both, :meta),
      lamp: lamps_for(rows) }
  end
end
