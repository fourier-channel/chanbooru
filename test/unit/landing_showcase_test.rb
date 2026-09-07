require "test_helper"

# The landing carousel's "new" row shows FRESH DEGEN and nothing else
# (operator, 2026-09-06). Before this, the row was `order:id_desc`, which
# ranks by post record rather than by picture: an archive backfill was "new"
# even when the image was years old, and a backfill run drowned the live
# capture the row exists to show.
class LandingShowcaseTest < ActiveSupport::TestCase
  BOARD = "https://boards.4chan.org/b/thread/953493575#p953493576".freeze
  OTHER_BOARD = "https://boards.4chan.org/d/thread/11389948#p11445593".freeze

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

  context "the showcase" do
    should "take the row from the database, so an admin can change it without a deploy" do
      LandingSetting.create!(board: "trash", fresh_only: false, label: "From the bin")
      spec = LandingShowcase.categories.find { |c| c[:key] == "new" }
      assert_equal "From the bin", spec[:label]
      assert_equal "source:https://boards.4chan.org/trash/*", spec[:query]
    end
  end
end
