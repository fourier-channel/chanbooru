require "test_helper"

# The landing carousel's "new" row shows FRESH DEGEN and nothing else
# (operator, 2026-09-06). Before this, the row was `order:id_desc`, which
# ranks by post record rather than by picture: an archive backfill was "new"
# even when the image was years old, and a backfill run drowned the live
# capture the row exists to show.
class LandingShowcaseTest < ActiveSupport::TestCase
  BOARD = "https://boards.4chan.org/b/thread/953493575#p953493576".freeze
  OTHER_BOARD = "https://boards.4chan.org/d/thread/11389948#p11445593".freeze

  context "the new row's query" do
    should "stay within the two tags an anonymous visitor may search" do
      # The landing page runs as whoever is looking at it, and a logged-out
      # visitor is exactly who it is for. A third term does not narrow the
      # row, it EMPTIES it, and `categories` drops an empty row silently --
      # so the page would simply lose its main feature with no error anywhere.
      terms = Danbooru.config.landing_new_query.split
      assert_operator terms.length, :<=, 2,
        "landing_new_query has #{terms.length} terms; anonymous search allows 2"
    end

    should "ask for the DEGEN board and exclude archive-sourced posts" do
      q = Danbooru.config.landing_new_query
      assert_includes q, "boards.4chan.org/b/", "the row is /b/, which is the DEGEN generals"
      assert_includes q, "-no_train", "archive-sourced bytes carry no_train; fresh captures do not"
    end

    should "not spend a term on ordering, which is already the default" do
      refute_includes Danbooru.config.landing_new_query, "order:",
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
    should "take the new row's query and label from config, not from a constant" do
      spec = LandingShowcase.categories.find { |c| c[:key] == "new" }
      assert_equal Danbooru.config.landing_new_query, spec[:query]
      assert_equal Danbooru.config.landing_new_label, spec[:label]
    end
  end
end
