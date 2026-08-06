# frozen_string_literal: true

# Sort-aware post neighbours -- the true previous/next post for ANY of Danbooru's
# `order:` sorts, not just by id.
#
# Danbooru's built-in search navbar walks by id only and explicitly gives up on
# ordered searches (PostNavbarComponent#has_search_navbar? excludes order:), so
# the redesigned gallery navigation needs this. The "active sort" is simply the
# order: metatag in the search query (default id_desc), so honouring order:
# covers every sort the booru exposes.
#
# Each neighbour is a keyset seek -- one indexed `LIMIT 1` lookup anchored on the
# current post's sort key, never an OFFSET scan. Sorts we can't keyset cleanly
# (random, rank, aggregate/nullable columns) fall back to the id walk, matching
# upstream behaviour rather than lying about the order.
class PostNeighbors
  # column is a TRUSTED SQL expression (from this table, never user input).
  # value extracts the current post's key for that column. posts.id is the unique
  # tiebreaker in every sort, so a keyset seek on (column, id) is exact.
  Spec = Struct.new(:join, :column, :dir, :value, keyword_init: true)

  SPECS = {
    "id"              => Spec.new(column: "posts.id", dir: :asc,  value: ->(p) { p.id }),
    "id_asc"          => Spec.new(column: "posts.id", dir: :asc,  value: ->(p) { p.id }),
    "id_desc"         => Spec.new(column: "posts.id", dir: :desc, value: ->(p) { p.id }),
    "created_at"      => Spec.new(column: "posts.created_at", dir: :desc, value: ->(p) { p.created_at }),
    "created_at_desc" => Spec.new(column: "posts.created_at", dir: :desc, value: ->(p) { p.created_at }),
    "created_at_asc"  => Spec.new(column: "posts.created_at", dir: :asc,  value: ->(p) { p.created_at }),
    "score"           => Spec.new(column: "posts.score", dir: :desc, value: ->(p) { p.score }),
    "score_desc"      => Spec.new(column: "posts.score", dir: :desc, value: ->(p) { p.score }),
    "score_asc"       => Spec.new(column: "posts.score", dir: :asc,  value: ->(p) { p.score }),
    "favcount"        => Spec.new(column: "posts.fav_count", dir: :desc, value: ->(p) { p.fav_count }),
    "favcount_asc"    => Spec.new(column: "posts.fav_count", dir: :asc,  value: ->(p) { p.fav_count }),
    "change"          => Spec.new(column: "posts.updated_at", dir: :desc, value: ->(p) { p.updated_at }),
    "change_desc"     => Spec.new(column: "posts.updated_at", dir: :desc, value: ->(p) { p.updated_at }),
    "change_asc"      => Spec.new(column: "posts.updated_at", dir: :asc,  value: ->(p) { p.updated_at }),
    "tagcount"        => Spec.new(column: "posts.tag_count", dir: :desc, value: ->(p) { p.tag_count }),
    "tagcount_desc"   => Spec.new(column: "posts.tag_count", dir: :desc, value: ->(p) { p.tag_count }),
    "tagcount_asc"    => Spec.new(column: "posts.tag_count", dir: :asc,  value: ->(p) { p.tag_count }),
    "filesize"        => Spec.new(join: :media_asset, column: "media_assets.file_size", dir: :desc, value: ->(p) { p.media_asset&.file_size }),
    "filesize_desc"   => Spec.new(join: :media_asset, column: "media_assets.file_size", dir: :desc, value: ->(p) { p.media_asset&.file_size }),
    "filesize_asc"    => Spec.new(join: :media_asset, column: "media_assets.file_size", dir: :asc,  value: ->(p) { p.media_asset&.file_size }),
    "mpixels"         => Spec.new(join: :media_asset, column: "media_assets.image_width * media_assets.image_height", dir: :desc, value: ->(p) { px(p) }),
    "mpixels_desc"    => Spec.new(join: :media_asset, column: "media_assets.image_width * media_assets.image_height", dir: :desc, value: ->(p) { px(p) }),
    "mpixels_asc"     => Spec.new(join: :media_asset, column: "media_assets.image_width * media_assets.image_height", dir: :asc,  value: ->(p) { px(p) }),
  }.freeze

  def self.px(post)
    ma = post.media_asset
    ma && ma.image_width * ma.image_height
  end

  attr_reader :post, :tags, :user, :order

  def initialize(post:, tags: nil, user: CurrentUser.user)
    @post = post
    @tags = tags.presence || "status:any"
    @user = user
    @order = PostQuery.new(@tags).find_metatag(:order).presence&.downcase || "id_desc"
  end

  def next_id = neighbor(:next)&.id
  def prev_id = neighbor(:prev)&.id

  # { prev:, next:, order: } -- ids or nil at the ends of the sequence.
  def to_h = { prev: prev_id, next: next_id, order: order }

  private

  def base = Post.user_tag_match(tags, user)

  def neighbor(direction)
    spec = SPECS[order]
    return id_walk(direction) if spec.nil?

    v = spec.value.call(post)
    return id_walk(direction) if v.nil?

    # Display order is (column dir, id dir). "next" follows the current post in
    # that order, "prev" precedes it. When descending, "after" means a smaller
    # column value (or equal value and smaller id); ascending is the mirror.
    forward = (direction == :next)
    descending = (spec.dir == :desc)
    op = (descending == forward) ? "<" : ">"
    seek = (op == "<") ? "DESC" : "ASC"
    col = spec.column

    rel = base
    rel = rel.joins(spec.join) if spec.join
    rel
      .where("#{col} #{op} ? OR (#{col} = ? AND posts.id #{op} ?)", v, v, post.id)
      .reorder(Arel.sql("#{col} #{seek}, posts.id #{seek}"))
      .first
  end

  # Fallback for orders we don't keyset: the id walk (upstream's own behaviour).
  def id_walk(direction)
    if direction == :next
      base.where("posts.id < ?", post.id).reorder("posts.id DESC").first
    else
      base.where("posts.id > ?", post.id).reorder("posts.id ASC").first
    end
  end
end
