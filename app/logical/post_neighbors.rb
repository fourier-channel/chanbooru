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
# Each side is a keyset seek -- one indexed `LIMIT n` lookup anchored on the
# current post's sort key, never an OFFSET scan. The post view asks for DEPTH
# candidates a side (run), because a neighbour the viewer's client-side
# blocklist hides must not be the thumbnail or the destination, and the next
# allowed one has to be in hand already (GALLERY_WINDOW.md section 2). Measured
# on production 2026-10-17: LIMIT 7 costs at most 1.5x LIMIT 1 on every search
# shape tried, with no plan flips. Sorts we can't keyset cleanly
# (random, rank, aggregate/nullable columns) fall back to the id walk, matching
# upstream behaviour rather than lying about the order.
class PostNeighbors
  # column is a TRUSTED SQL expression (from this table, never user input).
  # value extracts the current post's key for that column. posts.id is the unique
  # tiebreaker in every sort, so a keyset seek on (column, id) is exact. time
  # marks a timestamp column, whose key travels as integer microseconds.
  Spec = Struct.new(:join, :column, :dir, :value, :time, keyword_init: true)

  SPECS = {
    "id"              => Spec.new(column: "posts.id", dir: :asc,  value: ->(p) { p.id }),
    "id_asc"          => Spec.new(column: "posts.id", dir: :asc,  value: ->(p) { p.id }),
    "id_desc"         => Spec.new(column: "posts.id", dir: :desc, value: ->(p) { p.id }),
    "created_at"      => Spec.new(column: "posts.created_at", dir: :desc, value: ->(p) { p.created_at }, time: true),
    "created_at_desc" => Spec.new(column: "posts.created_at", dir: :desc, value: ->(p) { p.created_at }, time: true),
    "created_at_asc"  => Spec.new(column: "posts.created_at", dir: :asc,  value: ->(p) { p.created_at }, time: true),
    "score"           => Spec.new(column: "posts.score", dir: :desc, value: ->(p) { p.score }),
    "score_desc"      => Spec.new(column: "posts.score", dir: :desc, value: ->(p) { p.score }),
    "score_asc"       => Spec.new(column: "posts.score", dir: :asc,  value: ->(p) { p.score }),
    "favcount"        => Spec.new(column: "posts.fav_count", dir: :desc, value: ->(p) { p.fav_count }),
    "favcount_asc"    => Spec.new(column: "posts.fav_count", dir: :asc,  value: ->(p) { p.fav_count }),
    "change"          => Spec.new(column: "posts.updated_at", dir: :desc, value: ->(p) { p.updated_at }, time: true),
    "change_desc"     => Spec.new(column: "posts.updated_at", dir: :desc, value: ->(p) { p.updated_at }, time: true),
    "change_asc"      => Spec.new(column: "posts.updated_at", dir: :asc,  value: ->(p) { p.updated_at }, time: true),
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

  # A cursor that names no place in its search. A PostQuery::Error, so it is
  # answered 422 with its message, which names the fix.
  class NoPlace < PostQuery::Error; end

  # A PLACE IN A SORTED SEARCH, and the SQL that pages from it: the post page's
  # neighbour lookup (#run) and the Modulation gallery window's cursor
  # (PostSets::Post#seek; GALLERY_WINDOW.md section 2) are one keyset.
  #
  # Every sort the window pages is one of four kinds (Seek.kind):
  #   key     -- a SPECS sort: seek on (column, posts.id) from a cursor
  #              `<id>~<key>`, which carries the post's sort key, so opening it
  #              reads no post row -- a cursor keeps its place when its post is
  #              hidden or deleted later, and cannot be used to ask whether a
  #              hidden post exists. `<id>` alone is accepted (an id sort's key
  #              IS its id; any other key is looked up in the search, #resolve).
  #   offset  -- every other order: a position `@<n>`, paged by OFFSET, so it
  #              is bounded by the page limit and results may shift between
  #              fetches. A key sort accepts a position too, as the way in from
  #              an old `page=N` link.
  #   draw    -- order:random: a sample, so there is no place to return to.
  #   refused -- order:none: no order to page through.
  #
  # The key sort owns its ORDER BY -- `column dir, posts.id dir`, never
  # order_matches, which leaves no id tiebreak on created_at, tagcount,
  # filesize and mpixels -- and an id sort's is exactly `posts.id DESC`/`ASC`,
  # which is what PostQueryBuilder#optimize_search recognises.
  #
  # Forward runs in display order from the cursor; backward runs before it,
  # nearest first in SQL and flipped for display by the paginator.
  class Seek
    CURSOR = /\A(?<id>\d{1,10})~(?<key>-?\d{1,20})\z/
    BARE = /\A(?<id>\d{1,10})\z/
    POSITION = /\A@(?<offset>\d{1,9})\z/
    # The keys a place can carry: a timestamp's microseconds from year 1 to
    # year 9999 (Ruby's range; past it SQL multiplies the key into an interval
    # out of range, a database error and a 500), any other key a bigint.
    TIME_KEYS = (Time.utc(1).to_i * 1_000_000)..((Time.utc(9999, 12, 31, 23, 59, 59).to_i * 1_000_000) + 999_999)
    INT_KEYS = (-(2**63))..((2**63) - 1)

    NOT_A_PLACE = "That anchor is not a place in a search (it takes <id>~<key>, <id> or @<position>). Fix: open the search without anchor= or before=."
    NOT_IN_SEARCH = "That post is not in this search. Fix: open the search without an anchor."
    OTHER_SORT = "That place was marked under a different sort. Fix: open the search without anchor= or before=."
    NO_ORDER = "order:none has no order to page through. Fix: pick a sort, or open the search without anchor= or before=."
    NO_RETURN = "order:random has no place to return to: every look is a fresh draw. Fix: open the search without anchor= or before=."

    attr_reader :spec, :id, :key, :offset, :direction, :inclusive

    # @param order [String, Symbol] PostQueryBuilder#effective_order's answer
    def self.kind(order)
      case order
      when :random then :draw
      when :none then :refused
      else SPECS.key?(order) ? :key : :offset
      end
    end

    # The first chunk of a search: the key sort's own order, or the listing's.
    def self.head(order)
      refuse_kind!(order)
      new(spec: SPECS[order], offset: SPECS.key?(order) ? nil : 0)
    end

    # anchor= is :forward and inclusive (the anchor is the top-left post);
    # before= is :backward and exclusive.
    def self.parse(order, cursor, direction:)
      refuse_kind!(order)
      spec = SPECS[order]
      inclusive = (direction == :forward)

      if (m = POSITION.match(cursor.to_s))
        new(spec: spec, offset: m[:offset].to_i, direction: direction)
      elsif (m = CURSOR.match(cursor.to_s))
        raise NoPlace, OTHER_SORT if spec.nil?
        raise NoPlace, NOT_A_PLACE unless (spec.time ? TIME_KEYS : INT_KEYS).cover?(m[:key].to_i)

        new(spec: spec, id: m[:id].to_i, key: m[:key].to_i, direction: direction, inclusive: inclusive)
      elsif (m = BARE.match(cursor.to_s))
        raise NoPlace, OTHER_SORT if spec.nil?

        id = m[:id].to_i
        new(spec: spec, id: id, key: (spec.column == "posts.id") ? id : nil, direction: direction, inclusive: inclusive)
      else
        raise NoPlace, NOT_A_PLACE
      end
    end

    def self.refuse_kind!(order)
      raise NoPlace, NO_ORDER if kind(order) == :refused
      raise NoPlace, NO_RETURN if kind(order) == :draw
    end

    # A post's cursor under a key sort, or nil where it has none.
    def self.mint(post, order)
      spec = SPECS[order]
      key = spec && key_of(spec, spec.value.call(post))
      "#{post.id}~#{key}" unless key.nil?
    end

    # An integer key: timestamps as integer microseconds, exactly.
    def self.key_of(spec, value)
      return nil if value.nil?

      spec.time ? (value.to_r * 1_000_000).to_i : value.to_i
    end

    def initialize(spec:, id: nil, key: nil, offset: nil, direction: :forward, inclusive: false)
      @spec = spec
      @id = id
      @key = key
      @offset = offset
      @direction = direction
      @inclusive = inclusive
    end

    def backward? = direction == :backward

    # A keyset backward page is fetched nearest first and flipped for display;
    # an offset page is fetched in display order either way.
    def reversed? = backward? && offset.nil?

    # A bare id's key, read from this search's own rows. A post that is
    # missing, hidden from the viewer, deleted or outside the search answers
    # the same refusal, so it tells nobody which of those it was.
    def resolve(relation)
      return self unless id && key.nil?

      rel = spec.join ? relation.joins(spec.join) : relation
      found = rel.reorder(nil).where(posts: { id: id }).pick(Arel.sql(spec.column))
      raise NoPlace, NOT_IN_SEARCH if found.nil?

      Seek.new(spec: spec, id: id, key: Seek.key_of(spec, found), direction: direction, inclusive: inclusive)
    end

    # One chunk: `limit` rows and one more, so the paginator can tell whether
    # another lies past them -- except an offset page going backward, whose
    # start says so (#more?).
    def page(relation, limit)
      return apply(relation).limit(limit + 1) if offset.nil?

      rel = spec ? relation.reorder(Arel.sql(order_sql(:forward))) : relation
      rel = rel.joins(spec.join) if spec&.join
      return rel.offset(offset).limit(limit + 1) unless backward?

      start = [offset - limit, 0].max
      rel.offset(start).limit(offset - start)
    end

    # @param loaded [Integer] the rows #page fetched
    def more?(loaded, limit)
      (backward? && offset) ? offset > limit : loaded > limit
    end

    # The keyset: the rows on this side of the cursor, nearest first.
    def apply(relation)
      rel = spec.join ? relation.joins(spec.join) : relation
      rel = rel.where(*predicate) unless id.nil?
      rel.reorder(Arel.sql(order_sql(direction)))
    end

    private

    def id_sort? = spec.column == "posts.id"

    # Display order is (column dir, id dir); forward follows it, backward
    # runs against it.
    def order_sql(way)
      descending = (spec.dir == :desc) == (way == :forward)
      word = descending ? "DESC" : "ASC"
      id_sort? ? "posts.id #{word}" : "#{spec.column} #{word}, posts.id #{word}"
    end

    # When the seek runs descending, "past the cursor" means a smaller key (or
    # an equal key and a smaller id); ascending is the mirror.
    def predicate
      op = ((spec.dir == :desc) == (direction == :forward)) ? "<" : ">"
      id_op = inclusive ? "#{op}=" : op
      return ["posts.id #{id_op} ?", id] if id_sort?

      col = spec.column
      # A timestamp key is rebuilt from its microseconds in SQL, exactly.
      val = spec.time ? "(TIMESTAMP 'epoch' + ? * INTERVAL '1 microsecond')" : "?"
      ["#{col} #{op} #{val} OR (#{col} = #{val} AND posts.id #{id_op} ?)", key, key, id]
    end
  end

  attr_reader :post, :tags, :user, :order

  def initialize(post:, tags: nil, user: CurrentUser.user)
    @post = post
    @tags = tags.presence || "status:any"
    @user = user
    @order = PostQuery.new(@tags).find_metatag(:order).presence&.downcase || "id_desc"
  end

  # Flank candidates a side: the thumbnail is the first of them the viewer's
  # blocklist allows.
  DEPTH = 6

  # { ids:, more: } -- the next `depth` post ids in `direction`, nearest
  # first, and whether a row lies past them. One more row than asked for is
  # fetched, so `more` is exact: exactly `depth` remaining is not more.
  def run(direction, depth = DEPTH)
    ids = neighbor_ids(direction, depth + 1)
    { ids: ids.first(depth), more: ids.size > depth }
  end

  def next_id = run(:next, 1)[:ids].first
  def prev_id = run(:prev, 1)[:ids].first

  # { prev:, next:, order: } -- ids or nil at the ends of the sequence.
  def to_h = { prev: prev_id, next: next_id, order: order }

  private

  def base = Post.user_tag_match(tags, user)

  def neighbor_ids(direction, limit)
    spec = SPECS[order]
    return id_walk(direction, limit) if spec.nil?

    key = Seek.key_of(spec, spec.value.call(post))
    return id_walk(direction, limit) if key.nil?

    # "next" follows the current post in display order, "prev" precedes it.
    seek = Seek.new(spec: spec, id: post.id, key: key, direction: (direction == :next) ? :forward : :backward)
    seek.apply(base).limit(limit).pluck("posts.id")
  end

  # Fallback for orders we don't keyset: the id walk (upstream's own behaviour).
  def id_walk(direction, limit)
    if direction == :next
      base.where(posts: { id: ...post.id }).reorder("posts.id DESC").limit(limit).pluck("posts.id")
    else
      base.where("posts.id > ?", post.id).reorder("posts.id ASC").limit(limit).pluck("posts.id")
    end
  end
end
