require "test_helper"

# The landing carousel's "new" row shows FRESH DEGEN and nothing else
# (operator, 2026-09-06). Before this, the row was `order:id_desc`, which
# ranks by post record rather than by picture: an archive backfill was "new"
# even when the image was years old, and a backfill run drowned the live
# capture the row exists to show.
class LandingShowcaseTest < ActiveSupport::TestCase
  BOARD = "https://boards.4chan.org/b/thread/953493575#p953493576"
  OTHER_BOARD = "https://boards.4chan.org/d/thread/11389948#p11445593"

  # Class level, not inside a context: shoulda runs each `should` block through
  # instance_exec, so a `def` written inside a context is not on the object the
  # block runs against and raises NoMethodError.
  def new_ids(viewer)
    LandingShowcase.new(viewer: viewer).categories
                   .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
  end

  # The "new" row as a database with no rows yields it. Class level for the
  # reason above -- it was written inside its context on 2026-09-17 and every
  # test that called it raised NameError from then on.
  def new_row
    LandingCategory.new(LandingCategory::DEFAULTS.find { |d| d[:key] == "new" })
  end

  # A board row as the console's Categories form can configure it.
  def board_row(board: "b", fresh_only: true, label: "x")
    LandingCategory.new(key: "new", kind: "board", ordering: "new", board: board, fresh_only: fresh_only, label: label)
  end

  # These were LandingSetting's, which configured the "new" row until the rows
  # moved onto LandingCategory (8b8f06cee). The rules moved with it, and they
  # are asserted where they are now enforced -- LandingSetting holds only the
  # slide speed, and a test of its old #query was a test of code nothing ran.
  context "a board row's configuration" do
    should "assemble a search of two terms whatever is configured" do
      # The panel offers structured choices precisely so this cannot be broken
      # from the UI. Every combination it can produce is checked here.
      [%w[b true], %w[b false], %w[trash true], %w[d false]].each do |board, fresh|
        row = board_row(board: board, fresh_only: fresh == "true")
        assert_operator row.max_terms, :<=, LandingCategory::MAX_TERMS, "#{board}/#{fresh} produced #{row.queries}"
        assert_not_includes row.queries.sole, "order:", "an order term would spend one of the two for nothing"
      end
    end

    should "refuse a board slug that is really a query" do
      assert_not board_row(board: "b -no_train").valid?
      assert_not board_row(board: "/b/").valid?
      assert_not board_row(board: "").valid?
      assert board_row(board: "b").valid?
    end

    should "refuse an empty heading" do
      assert_not board_row(label: "").valid?
    end

    should "exclude archive-sourced posts only when asked" do
      assert_includes board_row(fresh_only: true).queries.sole, "-no_train"
      assert_not_includes board_row(fresh_only: false).queries.sole, "no_train"
    end
  end

  # These moved from LandingShowcase.new_row, which is gone: the row's config
  # lives on LandingCategory now, and so does the rule it has to obey.
  context "the new row's query" do
    should "stay within the two tags an anonymous visitor may search" do
      # The landing page runs as whoever is looking at it, and a logged-out
      # visitor is exactly who it is for. A third term does not narrow the
      # row, it EMPTIES it, and `categories` drops an empty row silently --
      # so the page would simply lose its main feature with no error anywhere.
      assert_operator new_row.max_terms, :<=, LandingCategory::MAX_TERMS,
                      "the new row asks for #{new_row.max_terms} terms; anonymous search allows #{LandingCategory::MAX_TERMS}"
    end

    should "ask for the DEGEN board and exclude archive-sourced posts" do
      q = new_row.queries.sole
      assert_includes q, "boards.4chan.org/b/", "the row is /b/, which is the DEGEN generals"
      assert_includes q, "-no_train", "archive-sourced bytes carry no_train; fresh captures do not"
    end

    should "not spend a term on ordering, which is already the default" do
      assert_not_includes new_row.queries.sole, "order:",
                          "newest-first is the default; an order: term costs a filter for nothing"
    end

    should "search each tag SEPARATELY, however many there are" do
      # The whole reason the table exists. Twenty featured artists is twenty
      # one-term searches; one twenty-term search returns nothing for a
      # logged-out visitor and the row vanishes with no error anywhere.
      row = LandingCategory.new(key: "featured", label: "Featured Creators", kind: "tags",
                                ordering: "new", tags: %w[alpha beta gamma delta])
      assert_equal(4, row.queries.length)
      assert_equal(1, row.max_terms)
      assert(row.valid?)
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
                           .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
      assert_includes ids, @fresh.id
    end

    should "not show an archive backfill, however new its post id is" do
      # The whole point: @backfill is the NEWEST record of the three by id.
      ids = LandingShowcase.new(viewer: User.anonymous).categories
                           .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
      assert_not_includes ids, @backfill.id
    end

    should "not show another board" do
      ids = LandingShowcase.new(viewer: User.anonymous).categories
                           .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
      assert_not_includes ids, @elsewhere.id
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
      assert_not_includes new_ids(User.anonymous), @deleted.id
    end

    should "drop a deleted post for a viewer who is allowed to see deleted posts" do
      # The case that was actually broken in production.
      assert_not_includes new_ids(create(:admin_user)), @deleted.id
    end

    should "drop a jailed post even if the delete half never landed" do
      # ModulationPostComponent#jailed? reads the tag rather than the flag for
      # this reason; the showcase now agrees with it.
      assert_not_includes new_ids(create(:admin_user)), @jailed.id
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
                              .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
      assert_equal slides.sort.reverse, slides, "ids must descend: the row is a queue, not a shuffle"
    end
  end

  # This asked LandingShowcase.categories, the class method that built the
  # specs in code, and wrote LandingSetting to steer it. Both went with
  # 8b8f06cee: the showcase reads LandingCategory, and a viewer's categories
  # are an instance method that drops a row with nothing in it. So it now
  # proves the whole claim on real posts -- the saved row's heading AND its
  # board, the latter by what the row shows and what it no longer shows.
  context "the showcase" do
    should "take the row from the database, so an admin can change it without a deploy" do
      new_default = LandingCategory::DEFAULTS.find { |d| d[:key] == "new" }
      LandingCategory.create!(new_default.merge(board: "trash", fresh_only: false, label: "From the bin"))
      user = create(:user)
      binned = as(user) { create(:post, source: "https://boards.4chan.org/trash/thread/1#p2") }
      degen = as(user) { create(:post, source: BOARD) }

      row = LandingShowcase.new(viewer: User.anonymous).categories.find { |c| c[:key] == "new" }

      assert_not_nil row, "the new row came back empty, so it did not search /trash/"
      assert_equal "From the bin", row[:label]
      assert_equal ["source:https://boards.4chan.org/trash/*"], LandingCategory.find_by!(key: "new").queries
      assert_includes row[:slides].pluck(:id), binned.id
      assert_not_includes row[:slides].pluck(:id), degen.id, "the default /b/ search is still what ran"
    end
  end
end
