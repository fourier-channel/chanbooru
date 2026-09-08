require "test_helper"

# The landing carousel's "new" row shows FRESH DEGEN and nothing else
# (operator, 2026-09-06). Before this, the row was `order:id_desc`, which
# ranks by post record rather than by picture: an archive backfill was "new"
# even when the image was years old, and a backfill run drowned the live
# capture the row exists to show.
class LandingShowcaseTest < ActiveSupport::TestCase
  BOARD = "https://boards.4chan.org/b/thread/953493575#p953493576".freeze
  OTHER_BOARD = "https://boards.4chan.org/d/thread/11389948#p11445593".freeze

  # Class level, not inside a context: shoulda runs each `should` block through
  # instance_exec, so a `def` written inside a context is not on the object the
  # block runs against and raises NoMethodError.
  def new_ids(viewer)
    LandingShowcase.new(viewer: viewer).categories
      .find { |c| c[:key] == "new" }.to_h[:slides].to_a.map { |s| s[:id] }
  end

  context "the setting that drives the row" do
    should "assemble a search of two terms whatever is configured" do
      # The panel offers structured choices precisely so this cannot be broken
      # from the UI. Every combination it can produce is checked here.
      [%w[b true], %w[b false], %w[trash true], %w[d false]].each do |board, fresh|
        s = LandingSetting.new(board: board, fresh_only: fresh == "true", label: "x")
        assert_operator s.term_count, :<=, 2, "#{board}/#{fresh} produced #{s.query}"
        refute_includes s.query, "order:", "an order term would spend one of the two for nothing"
      end
    end

    should "refuse a board slug that is really a query" do
      refute LandingSetting.new(board: "b -no_train", label: "x").valid?
      refute LandingSetting.new(board: "/b/", label: "x").valid?
      refute LandingSetting.new(board: "", label: "x").valid?
      assert LandingSetting.new(board: "b", label: "x").valid?
    end

    should "refuse an empty heading" do
      refute LandingSetting.new(board: "b", label: "").valid?
    end

    should "exclude archive-sourced posts only when asked" do
      assert_includes LandingSetting.new(board: "b", fresh_only: true, label: "x").query, "-no_train"
      refute_includes LandingSetting.new(board: "b", fresh_only: false, label: "x").query, "no_train"
    end
  end

  context "the new row's query" do
    should "stay within the two tags an anonymous visitor may search" do
      # The landing page runs as whoever is looking at it, and a logged-out
      # visitor is exactly who it is for. A third term does not narrow the
      # row, it EMPTIES it, and `categories` drops an empty row silently --
      # so the page would simply lose its main feature with no error anywhere.
      terms = LandingShowcase.new_row[:query].split
      assert_operator terms.length, :<=, 2,
        "landing_new_query has #{terms.length} terms; anonymous search allows 2"
    end

    should "ask for the DEGEN board and exclude archive-sourced posts" do
      q = LandingShowcase.new_row[:query]
      assert_includes q, "boards.4chan.org/b/", "the row is /b/, which is the DEGEN generals"
      assert_includes q, "-no_train", "archive-sourced bytes carry no_train; fresh captures do not"
    end

    should "not spend a term on ordering, which is already the default" do
      refute_includes LandingShowcase.new_row[:query], "order:",
        "newest-first is the default; an order: term costs a filter for nothing"
    end
  end

  context "the row itself, against real posts" do
    setup do
      @user = create(:user)
      @fresh = as(@user) { create(:post, source: BOARD) }
      @backfill = as(@user) { create(:post, source: BOARD, tag_string: "no_train") }
      @elsewhere = as(@user) { create(:post, source: OTHER_BOARD) }
    end

    should "show a fresh DEGEN capture" do
      ids = LandingShowcase.new(viewer: User.anonymous).categories
        .find { |c| c[:key] == "new" }.to_h[:slides].to_a.map { |s| s[:id] }
      assert_includes ids, @fresh.id
    end

    should "not show an archive backfill, however new its post id is" do
      # The whole point: @backfill is the NEWEST record of the three by id.
      ids = LandingShowcase.new(viewer: User.anonymous).categories
        .find { |c| c[:key] == "new" }.to_h[:slides].to_a.map { |s| s[:id] }
      refute_includes ids, @backfill.id
    end

    should "not show another board" do
      ids = LandingShowcase.new(viewer: User.anonymous).categories
        .find { |c| c[:key] == "new" }.to_h[:slides].to_a.map { |s| s[:id] }
      refute_includes ids, @elsewhere.id
    end
  end

  # A jailed or deleted picture must leave the showcase, for EVERY viewer.
  #
  # It did not. showable? asked Post#visible?, which asks about safe mode,
  # level and bans and never about is_deleted; and the query path here skips
  # with_implicit_metatags, so the implicit -status:deleted never applied
  # either. The only thing keeping jailed posts out was levelblocked? tripping
  # on troll_jail being in restricted_tags -- which holds for an anonymous
  # viewer and fails for anyone who can see deleted posts. The operator is
  # level 60: they jailed an image and it stayed in their carousel.
  #
  # Both viewers are asserted deliberately. Testing only the anonymous one
  # would have passed against the broken code.
  context "a post that has been removed" do
    setup do
      @user = create(:user)
      @ok = as(@user) { create(:post, source: BOARD) }
      @deleted = as(@user) { create(:post, source: BOARD) }
      @deleted.update!(is_deleted: true)
      @jailed = as(@user) { create(:post, source: BOARD, tag_string: Danbooru.config.troll_jail_tag) }
    end

    should "keep an ordinary post" do
      assert_includes new_ids(User.anonymous), @ok.id
    end

    should "drop a deleted post for an anonymous viewer" do
      refute_includes new_ids(User.anonymous), @deleted.id
    end

    should "drop a deleted post for a viewer who is allowed to see deleted posts" do
      # The case that was actually broken in production.
      refute_includes new_ids(create(:admin_user)), @deleted.id
    end

    should "drop a jailed post even if the delete half never landed" do
      # ModulationPostComponent#jailed? reads the tag rather than the flag for
      # this reason; the showcase now agrees with it.
      refute_includes new_ids(create(:admin_user)), @jailed.id
    end
  end

  context "filling the row" do
    setup do
      @user = create(:user)
      # Twelve qualifying posts, with non-qualifying ones interleaved so the
      # showable? filter has something to eat. A window of exactly 2x the
      # target used to come back short -- the live row was showing eight.
      15.times { as(@user) { create(:post, source: BOARD) } }
    end

    should "show a full row when there are enough posts to fill it" do
      slides = LandingShowcase.new(viewer: User.anonymous).categories
        .find { |c| c[:key] == "new" }.to_h[:slides].to_a
      assert_equal LandingShowcase::PER_CATEGORY, slides.length,
        "the row must fill to PER_CATEGORY when the posts exist"
    end

    should "be newest first, so a new post displaces the oldest rather than reshuffling" do
      slides = LandingShowcase.new(viewer: User.anonymous).categories
        .find { |c| c[:key] == "new" }.to_h[:slides].to_a.map { |s| s[:id] }
      assert_equal slides.sort.reverse, slides, "ids must descend: the row is a queue, not a shuffle"
    end
  end

  context "the showcase" do
    should "take the row from the database, so an admin can change it without a deploy" do
      LandingSetting.create!(board: "trash", fresh_only: false, label: "From the bin")
      spec = LandingShowcase.categories.find { |c| c[:key] == "new" }
      assert_equal "From the bin", spec[:label]
      assert_equal "source:https://boards.4chan.org/trash/*", spec[:query]
    end
  end
end
