# frozen_string_literal: true

require "test_helper"

# PostNeighbors::Seek: a place in a sorted search, and the SQL that pages from
# it -- the cursor the Modulation gallery window carries (GALLERY_WINDOW.md
# section 2) and the post page's neighbour lookup, one keyset for both.
#
# The window walks a search in chunks from a cursor, forward from an anchor
# (inclusive: the anchor is the top-left post) and backward before one
# (exclusive). Every chunk boundary is a seam, and a seam inside a run of
# equal sort keys is where a keyset without a unique tiebreak skips or
# repeats posts. So every sort here is walked over deliberate ties and held
# to Ruby's sort on [key, id].
class PostWindowSeekTest < ActiveSupport::TestCase
  Seek = PostNeighbors::Seek

  setup do
    @user = create(:user)
    CurrentUser.user = @user
    stamp = Time.utc(2026, 1, 2, 3, 4, 5, 123_456r)
    # Ties on every key: three scores, two tag counts, two timestamps to the
    # microsecond, two file sizes and two pixel counts (10x20 = 20x10).
    shapes = [
      [1, "a b", 0, 100, [10, 20]], [1, "a b c", 1, 100, [20, 10]], [2, "a b", 0, 200, [10, 20]],
      [2, "a b c", 1, 200, [30, 30]], [3, "a b", 0, 100, [20, 10]], [1, "a b", 1, 200, [10, 20]],
      [2, "a b c", 0, 100, [30, 30]], [3, "a b c", 1, 200, [10, 20]],
    ]
    @posts = shapes.map do |score, tags, tick, size, (w, h)|
      post = create(:post, tag_string: "seektie #{tags}")
      at = stamp + tick.seconds
      post.update_columns(score: score, fav_count: score, created_at: at, updated_at: at) # rubocop:disable Rails/SkipsModelValidations
      post.media_asset.update_columns(file_size: size, image_width: w, image_height: h) # rubocop:disable Rails/SkipsModelValidations
      post.reload
    end
  end

  teardown do
    CurrentUser.user = nil
  end

  def relation(order)
    PostQuery.normalize("seektie order:#{order}", current_user: @user).with_implicit_metatags.posts
  end

  def page(order, seek, limit)
    relation(order).paginate(nil, limit: limit, seek: seek, page_limit: 1000)
  end

  # The list the window must walk: each sort's own key, then the post id,
  # both in the sort's direction.
  def expected(order)
    spec = PostNeighbors::SPECS.fetch(order)
    keyed = @posts.map { |post| [Seek.key_of(spec, spec.value.call(post)), post.id] }.sort
    keyed.reverse! if spec.dir == :desc
    keyed.map(&:last)
  end

  def walk_forward(order, limit)
    seen = []
    seek = Seek.head(order)
    loop do
      chunk = page(order, seek, limit)
      rows = chunk.records
      # A chunk after the first starts AT its anchor, which the last one
      # ended on: the window drops that one repeat by id.
      assert_equal seen.last, rows.first&.id, "order:#{order}: the anchor opens its own chunk" if seen.any?
      seen.concat(seen.any? ? rows.drop(1).map(&:id) : rows.map(&:id))
      break unless chunk.more?

      seek = Seek.parse(order, Seek.mint(rows.last, order), direction: :forward)
    end
    seen
  end

  def walk_backward(order, limit)
    last = Post.find(expected(order).last)
    seen = [last.id]
    seek = Seek.parse(order, Seek.mint(last, order), direction: :backward)
    loop do
      chunk = page(order, seek, limit)
      rows = chunk.records
      seen = rows.map(&:id) + seen
      break unless chunk.more?

      seek = Seek.parse(order, Seek.mint(rows.first, order), direction: :backward)
    end
    seen
  end

  context "Seek" do
    should "walk every keyset sort forward and backward with no gap and no repeat" do
      PostNeighbors::SPECS.each_key do |order|
        assert_equal expected(order), walk_forward(order, 3), "forward, order:#{order}"
        assert_equal expected(order), walk_backward(order, 3), "backward, order:#{order}"
      end
    end

    should "say more only when a row lies past the chunk" do
      assert page("id_desc", Seek.head("id_desc"), 7).more?
      assert_not page("id_desc", Seek.head("id_desc"), 8).more?, "exactly the last page"
      assert_equal expected("id_desc").first(7), page("id_desc", Seek.head("id_desc"), 7).records.map(&:id)
    end

    should "come out in display order going backward" do
      ids = expected("score")
      anchor = Post.find(ids[5])
      rows = page("score", Seek.parse("score", Seek.mint(anchor, "score"), direction: :backward), 3).records.map(&:id)
      assert_equal ids[2..4], rows
    end

    should "round-trip a timestamp to the microsecond" do
      one = @posts.first
      two = create(:post, tag_string: "seektie")
      two.update_columns(created_at: one.created_at + Rational(1, 1_000_000), updated_at: one.created_at) # rubocop:disable Rails/SkipsModelValidations
      cursor = Seek.mint(one, "created_at_asc")
      assert_equal "#{one.id}~#{(one.created_at.to_r * 1_000_000).to_i}", cursor
      rows = page("created_at_asc", Seek.parse("created_at_asc", cursor, direction: :forward), 20).records.map(&:id)
      assert_equal one.id, rows.first, "the anchor opens the chunk"
      assert_includes rows, two.id, "a post one microsecond later is after the anchor"
      before = page("created_at_asc", Seek.parse("created_at_asc", Seek.mint(two.reload, "created_at_asc"), direction: :backward), 20).records.map(&:id)
      assert_includes before, one.id, "and the anchor is before it"
      assert_not_includes before, two.id
      assert_equal two.id, page("created_at_asc", Seek.parse("created_at_asc", Seek.mint(two, "created_at_asc"), direction: :forward), 20).records.first.id
    end

    should "order id sorts by exactly posts.id, so a rare tag keeps its small-search plan" do
      %w[id_desc id id_asc].each do |order|
        values = page(order, Seek.head(order), 3).order_values.map { it.try(:to_sql) || it.to_s }
        assert_equal [(order == "id_desc") ? "posts.id DESC" : "posts.id ASC"], values, order
        anchored = page(order, Seek.parse(order, @posts[3].id.to_s, direction: :forward), 3).order_values.map(&:to_s)
        assert_equal 1, anchored.size, order
      end
    end

    should "refuse a place where there is no order to keep one" do
      assert_raises(PostNeighbors::NoPlace) { Seek.parse(:none, "5~1", direction: :forward) }
      assert_raises(PostNeighbors::NoPlace) { Seek.head(:none) }
      assert_raises(PostNeighbors::NoPlace) { Seek.parse(:random, "5~1", direction: :forward) }
      assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", "5~", direction: :forward) }
      assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", "x", direction: :forward) }
      assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", "1 OR 1=1", direction: :forward) }
      assert_raises(PostNeighbors::NoPlace) { Seek.parse("comment_bumped", "5~1", direction: :forward) }
      assert_kind_of PostQuery::Error, PostNeighbors::NoPlace.new, "answered 422 like any search error"
    end

    # A time key is multiplied into an interval in SQL; one past the range
    # was a database error, a 500 that named nothing.
    should "refuse a key outside its sort's range before it reaches SQL" do
      %w[created_at change_asc].each do |order|
        error = assert_raises(PostNeighbors::NoPlace) { Seek.parse(order, "1~99999999999999999999", direction: :forward) }
        assert_equal Seek::NOT_A_PLACE, error.message, order
        assert_raises(PostNeighbors::NoPlace, order) { Seek.parse(order, "1~-99999999999999999", direction: :backward) }
      end
      assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", "1~99999999999999999999", direction: :forward) }
      last = (Time.utc(9999, 12, 31, 23, 59, 59).to_r * 1_000_000).to_i
      assert_equal last, Seek.parse("created_at", "1~#{last}", direction: :forward).key, "the range's own edge is a place"
      assert_equal [], page("created_at", Seek.parse("created_at", "1~#{last}", direction: :backward), 3).records.to_a
    end

    should "find a bare id's key in the search, and refuse one the search does not hold" do
      post = @posts[2]
      seek = Seek.parse("score", post.id.to_s, direction: :forward).resolve(relation("score"))
      assert_equal post.id, page("score", seek, 3).records.first.id
      outside = create(:post, tag_string: "elsewhere")
      error = assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", outside.id.to_s, direction: :forward).resolve(relation("score")) }
      missing = assert_raises(PostNeighbors::NoPlace) { Seek.parse("score", "999999999", direction: :forward).resolve(relation("score")) }
      assert_equal error.message, missing.message, "not in the search and not at all read the same"
    end

    should "page a position-based sort by offset" do
      listed = relation("comment_bumped").to_a.map(&:id)
      head = page("comment_bumped", Seek.head("comment_bumped"), 3)
      assert_equal listed.first(3), head.records.map(&:id)
      assert head.more?
      later = page("comment_bumped", Seek.parse("comment_bumped", "@3", direction: :forward), 3)
      assert_equal listed[3..5], later.records.map(&:id)
      back = page("comment_bumped", Seek.parse("comment_bumped", "@5", direction: :backward), 3)
      assert_equal listed[2..4], back.records.map(&:id)
      assert back.more?
      assert_not page("comment_bumped", Seek.parse("comment_bumped", "@3", direction: :backward), 3).more?
    end

    should "enter a keyset sort at a position, for an old page= link" do
      assert_equal expected("score")[3..5], page("score", Seek.parse("score", "@3", direction: :forward), 3).records.map(&:id)
    end

    should "refuse a position past the page limit" do
      assert_raises(PaginationExtension::PaginationError) do
        relation("comment_bumped").paginate(nil, limit: 3, seek: Seek.parse("comment_bumped", "@100", direction: :forward), page_limit: 2).load
      end
    end

    should "mint nothing for a sort it cannot key" do
      assert_nil Seek.mint(@posts.first, "comment_bumped")
    end
  end
end
