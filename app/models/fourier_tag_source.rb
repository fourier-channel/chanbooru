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
    # ORIGINAL CHARACTERS (oc_<name>, operator 2026-09-19): the creator naming
    # a character in the prompt. Not resolved -- the name IS the tag -- and
    # not private: it is put on the post and filed as a character below.
    oc = fetch.call(:oc).map { |n| Tag.normalize_name(n) }.uniq.grep(ORIGINAL_CHARACTER)

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
    declare_original_characters!(post, oc, user) if oc.any?
    transaction do
      # A re-read of the bytes replaces the previous read: every row that
      # carries the creator bit goes, `both` included -- a tag still in both
      # lists comes straight back as both, one now only the autotagger's
      # comes back as auto, and one the prompt no longer yields is gone.
      where(post_id: post.id).where("source & ? > 0", CREATOR).delete_all if replace_creator
      upsert_all(rows.uniq { |r| r[:tag] }, unique_by: %i[post_id tag]) if rows.any?
    end
    rows.size
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

  # oc_<name>, character_oc_<name>, <name>_oc, <name>_character_oc -- both
  # shapes, with or without "character" (operator, 2026-09-19). Bare "oc" is
  # nobody's name. The same rule the tunnel's parser applies.
  ORIGINAL_CHARACTER = /\A(?:(?:character_)?oc_[a-z0-9].*|.*[a-z0-9]_(?:character_)?oc)\z/

  # An original character is DECLARED, not merely recorded: the name goes on
  # the post (public, so it is searchable and lands on the character shelf)
  # and its tag is filed under the character category. A tag that already
  # has a category other than general keeps it -- this never re-files
  # somebody's artist or copyright tag because a prompt said oc_.
  def self.declare_original_characters!(post, names, user)
    missing = names - post.tag_array
    if missing.any?
      CurrentUser.scoped(user || User.system) do
        post.add_tag(*missing)
        post.save!
      end
    end
    CurrentUser.scoped(user || User.system) do
      names.each do |name|
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
  def lamp
    return :both if spectrum? && hydra?
    return :hydra if hydra?
    return :spectrum if spectrum? || auto? || meta?

    :manual
  end

  # Can `viewer` see this post's PRIVATE (creator-only) tags? The creator (the
  # user attributed on the private rows), a moderator, or a holder of a view
  # TagGrant on one of the post's tags -- the whitelist a creator's tag
  # maintains. Nil viewer => no.
  def self.private_visible_to?(post, viewer)
    return false if viewer.nil?
    return true if viewer.respond_to?(:is_moderator?) && viewer.is_moderator?
    return true if TagGrant.granted?(viewer, post.tag_string.to_s.split, "view")

    where(post_id: post.id, public: false).where.not(added_by: nil).pluck(:added_by).uniq.include?(viewer.id)
  end

  # Tag buckets visible to `viewer` (identity-gated read): public rows always,
  # private rows only if the viewer is the creator/mod.
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
  def self.for_viewer(post, viewer)
    buckets, = buckets_and_lamps_for(post, viewer)
    buckets
  end

  # Buckets AND lamps from one pass over one query, for the caller that needs
  # both -- the post page. Returned as a pair rather than one merged hash for
  # the reason lamps_for gives.
  def self.buckets_and_lamps_for(post, viewer)
    current = post.tag_string.to_s.split
    rows = where(post_id: post.id, tag: current)
    known = rows.pluck(:tag)
    rows = rows.publicly_visible unless private_visible_to?(post, viewer)
    rows = rows.to_a
    [buckets_for(rows).merge(unsourced: current - known), lamps_for(rows)]
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
  def self.blacklist_tags_for(posts, viewer)
    posts = Array(posts)
    return {} if posts.empty?

    private_rows = where(post_id: posts.map(&:id), public: false).pluck(:post_id, :tag, :added_by)
    by_post = private_rows.group_by(&:first)
    moderator = viewer.respond_to?(:is_moderator?) && viewer.is_moderator?

    # viewer.id is nil for an anonymous viewer, and added_by is nil for any row
    # recorded without an attributed creator -- so a bare `added_by == viewer.id`
    # is nil == nil, and every unattributed private tag is disclosed to exactly
    # the viewer who should never see one. private_visible_to? guards this with
    # `.where.not(added_by: nil)`; the same guard has to be here.
    viewer_id = viewer.respond_to?(:id) ? viewer.id : nil
    # One query for the viewer's view grants, matched per post below -- the
    # bulk twin of the grant check in private_visible_to?.
    granted_tags = viewer_id.present? ? TagGrant.tags_for(viewer, "view") : []

    posts.index_with do |post|
      tags = post.tag_string.to_s.split
      rows = by_post[post.id]
      next tags if rows.blank? || moderator
      next tags if granted_tags.any? && (tags & granted_tags).any?
      next tags if viewer_id.present? && rows.any? { |(_, _, added_by)| added_by.present? && added_by == viewer_id }

      tags - rows.map { |(_, tag, _)| tag }
    end
  end

  # The PUBLIC-SAFE projection for the Matrix state event / anonymous views.
  # Private tags and unapproved suggestions are omitted -- nothing sensitive
  # ever leaves the gated store.
  def self.matrix_projection(post)
    # Same intersection as for_viewer, for the same reason: a row whose tag has
    # left the post is not provenance for anything.
    rows = where(post_id: post.id, public: true, status: APPROVED, tag: post.tag_string.to_s.split).to_a
    b = buckets_for(rows)
    { tags: (b[:creator] + b[:auto] + b[:both] + b[:meta]).uniq, sources: b.slice(:creator, :auto, :both, :meta),
      lamp: lamps_for(rows) }
  end
end
