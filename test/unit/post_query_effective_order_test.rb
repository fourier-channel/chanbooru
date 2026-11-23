# frozen_string_literal: true

require "test_helper"

# One order decision for the listing and the gallery window
# (PostQueryBuilder#effective_order). The window pages by the order the
# listing sorts by, so the two must read it from one place: a date: search
# typed with order:id is listed by created_at, and a window that keyset it by
# id would walk a different list from the one on screen.
class PostQueryEffectiveOrderTest < ActiveSupport::TestCase
  setup do
    CurrentUser.user = create(:user)
  end

  teardown do
    CurrentUser.user = nil
  end

  def effective(search)
    query = PostQuery.normalize(search, current_user: CurrentUser.user)
    query.builder.effective_order(query)
  end

  def listing_sql(search)
    PostQuery.normalize(search, current_user: CurrentUser.user).with_implicit_metatags.posts.to_sql
  end

  context "effective_order" do
    should "swap an id order for created_at under date: or age:, as the listing does" do
      assert_equal "created_at_asc", effective("date:2020-01-01 order:id")
      assert_equal "created_at_asc", effective("age:<1d order:id_asc")
      assert_equal "created_at_desc", effective("date:2020-01-01 order:id_desc")
      assert_equal "created_at_desc", effective("age:<1d")
      assert_equal "score", effective("age:<1d order:score")
    end

    should "read an unknown or missing order as id_desc, as order_matches falls back" do
      assert_equal "id_desc", effective("")
      assert_equal "id_desc", effective("touhou")
      assert_equal "id_desc", effective("touhou order:nonsense")
    end

    # The listing's default (ORIGINAL_DATES.md D4) travels as a PostQuery
    # option, never as a term in the search, so it survives every rebuild and
    # never shows in the search box. Only HTML listings pass it; the API's
    # default stays id_desc.
    should "take a missing order from the query's default_order" do
      default = PostQuery::LISTING_DEFAULT_ORDER
      assert_equal "posted_desc", default
      with_default = ->(search) { PostQuery.normalize(search, current_user: CurrentUser.user, default_order: default) }
      order_of = ->(search) { with_default.call(search).then { |q| q.builder.effective_order(q) } }

      assert_equal "posted_desc", order_of.call("")
      assert_equal "posted_desc", order_of.call("touhou")
      assert_equal "id_desc", order_of.call("touhou order:id_desc")
      assert_equal "score", order_of.call("touhou order:score")
      assert_equal "created_at_desc", order_of.call("age:<1d")

      query = with_default.call("touhou")
      assert_equal default, query.with_implicit_metatags.default_order
      assert_equal default, query.build(query.ast).default_order
      assert_equal default, query.without_taken_down.default_order
      assert query.with_implicit_metatags.posts.to_sql.end_with?("ORDER BY posts.source_created_at DESC, posts.id DESC")
      assert listing_sql("touhou").end_with?("ORDER BY posts.id DESC"), "no default_order: the API's id_desc"
    end

    # optimize_search forces a bitmap scan for a search known to be small; it
    # must recognise the posted orders, or a small tag under the default
    # order would walk the whole (source_created_at, id) index filtering.
    should "treat the posted orders as optimize_search treats id" do
      %w[id_desc id posted_desc posted_asc posted].each do |order|
        query = PostQuery.normalize("touhou order:#{order}", current_user: CurrentUser.user).with_implicit_metatags
        builder = query.builder
        relation = Post.unscoped.order_matches(order)
        builder.expects(:small_search).with(anything).returns(:small)
        assert_equal :small, builder.send(:optimize_search, relation, 5, 100), "order:#{order}"
      end

      query = PostQuery.normalize("touhou order:score", current_user: CurrentUser.user).with_implicit_metatags
      builder = query.builder
      relation = Post.unscoped.order_matches("score")
      builder.expects(:small_search).never
      assert_same relation, builder.send(:optimize_search, relation, 5, 100)
    end

    should "name the orders the window cannot keyset" do
      assert_equal :random, effective("order:random")
      assert_equal :random, effective("touhou random:5")
      assert_equal :random, effective("order:score random:5")
      assert_equal :none, effective("order:none")
      assert_equal :custom, effective("id:1,2 order:custom")
      assert_equal :ord_metatag, effective("ordfav:#{CurrentUser.user.name}")
      assert_equal :ord_metatag, effective("ordpool:1")
    end

    should "pass every other order through, downcased" do
      assert_equal "score", effective("order:SCORE")
      assert_equal "comment_bumped", effective("order:comment_bumped")
      assert_equal "rank", effective("order:rank")
    end

    should "leave the listing SQL unchanged for every gallery sort" do
      # Captured from the listing before effective_order existed: the ORDER BY
      # each sort produced. The listing must read the decision without moving.
      expected = {
        "id" => "posts.id ASC", "id_asc" => "posts.id ASC", "id_desc" => "posts.id DESC",
        "score" => "posts.score DESC, posts.id DESC", "score_asc" => "posts.score ASC, posts.id ASC",
        "favcount" => "posts.fav_count DESC, posts.id DESC", "favcount_asc" => "posts.fav_count ASC, posts.id ASC",
        "created_at" => "posts.created_at DESC", "created_at_asc" => "posts.created_at ASC", "created_at_desc" => "posts.created_at DESC",
        "change" => "posts.updated_at DESC, posts.id DESC", "change_asc" => "posts.updated_at ASC, posts.id ASC",
        "filesize" => "media_assets.file_size DESC", "filesize_asc" => "media_assets.file_size ASC",
        "mpixels" => "media_assets.image_width * media_assets.image_height / 1000000.0 DESC",
        "mpixels_asc" => "media_assets.image_width * media_assets.image_height / 1000000.0 ASC",
        "tagcount" => "posts.tag_count DESC", "tagcount_asc" => "posts.tag_count ASC",
        "random" => "random()",
        "posted" => "posts.source_created_at DESC, posts.id DESC", "posted_desc" => "posts.source_created_at DESC, posts.id DESC",
        "posted_asc" => "posts.source_created_at ASC, posts.id ASC",
      }
      assert_equal ModulationSetting::GALLERY_SORTS.sort, expected.keys.sort, "fixture: every gallery sort is pinned"
      expected.each do |sort, order_by|
        assert listing_sql("touhou order:#{sort}").end_with?("ORDER BY #{order_by}"), "order:#{sort}: #{listing_sql("touhou order:#{sort}")}"
      end
      assert listing_sql("date:2020-01-01 order:id").end_with?("ORDER BY posts.created_at ASC")
      assert listing_sql("touhou order:nonsense").end_with?("ORDER BY posts.id DESC")
    end
  end
end
