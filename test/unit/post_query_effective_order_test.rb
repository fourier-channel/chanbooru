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
