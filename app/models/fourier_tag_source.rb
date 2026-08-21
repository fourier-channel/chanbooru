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
  # partition (as bmb sends it). Idempotent per (post, tag). Creator-ONLY tags are
  # private by default (prompt-derived, may leak); everything else is public.
  def self.record_partition!(post, sources, user)
    now = Time.zone.now
    rows = []
    fetch = ->(k) { sources[k.to_s] || sources[k.to_sym] || [] }
    add = ->(tags, source, status, pub) { tags.each { |t| rows << { post_id: post.id, tag: t.to_s, source: source, status: status, public: pub, added_by: user&.id, created_at: now } } }
    add.call(fetch.call(:both),    CREATOR | AUTO, APPROVED, true)
    add.call(fetch.call(:creator), CREATOR,        APPROVED, false)
    add.call(fetch.call(:auto),    AUTO,           APPROVED, true)
    add.call(fetch.call(:meta),    META,           APPROVED, true)
    add.call(fetch.call(:pending), HUMAN,          PENDING,  true)
    upsert_all(rows.uniq { |r| r[:tag] }, unique_by: %i[post_id tag]) if rows.any?
    rows.size
  end

  # Group a relation of rows into { creator, auto, both, meta, pending } tag lists.
  def self.buckets_for(rows)
    out = { creator: [], auto: [], both: [], meta: [], pending: [] }
    rows.each { |r| out[r.bucket] << r.tag }
    out.transform_values(&:uniq)
  end

  # Can `viewer` see this post's PRIVATE (creator-only) tags? The creator (the
  # user attributed on the private rows) or a moderator. Nil viewer => no.
  def self.private_visible_to?(post, viewer)
    return false if viewer.nil?
    return true if viewer.respond_to?(:is_moderator?) && viewer.is_moderator?

    where(post_id: post.id, public: false).where.not(added_by: nil).pluck(:added_by).uniq.include?(viewer.id)
  end

  # Tag buckets visible to `viewer` (identity-gated read): public rows always,
  # private rows only if the viewer is the creator/mod.
  def self.for_viewer(post, viewer)
    rows = where(post_id: post.id)
    rows = rows.publicly_visible unless private_visible_to?(post, viewer)
    buckets_for(rows)
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

    posts.index_with do |post|
      tags = post.tag_string.to_s.split
      rows = by_post[post.id]
      next tags if rows.blank? || moderator
      next tags if viewer.present? && rows.any? { |(_, _, added_by)| added_by == viewer.id }

      tags - rows.map { |(_, tag, _)| tag }
    end
  end

  # The PUBLIC-SAFE projection for the Matrix state event / anonymous views.
  # Private tags and unapproved suggestions are omitted -- nothing sensitive
  # ever leaves the gated store.
  def self.matrix_projection(post)
    b = buckets_for(where(post_id: post.id, public: true, status: APPROVED))
    { tags: (b[:creator] + b[:auto] + b[:both] + b[:meta]).uniq, sources: b.slice(:creator, :auto, :both, :meta) }
  end
end
