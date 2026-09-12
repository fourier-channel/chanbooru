require "test_helper"

# `?redirect=true` combined with `?limit=1` -- the shape of every next/prev
# navigation link the media_assets pages emit -- used to answer 500.
#
# Upstream's redirect_to_show asks the relation twice: `one?` honours the
# relation's LIMIT, while `sole` calls `take(2)`, which on an unloaded
# relation replaces that LIMIT with 2. With one row under the limit and a
# second row behind it, `one?` says "exactly one" and `sole` then raises
# SoleRecordExceeded. Crawlers walking those links produced 1,310 500s in six
# hours on 2026-09-11, which is how it was found.
#
# These tests are written against the BEHAVIOUR a caller sees, not against the
# internals: the first one fails with a 500 on unpatched code, and the other
# three pin the behaviour the fix must not change.
class RedirectToShowTest < ActionDispatch::IntegrationTest
  context "redirect_to_show" do
    setup do
      @first = create(:media_asset)
      @second = create(:media_asset)
    end

    should "redirect to the first row rather than raising when limit=1 bounds a larger match" do
      get media_assets_path(limit: 1, redirect: true, search: { id: ">0", order: "id_asc" }), as: :json

      assert_response :redirect
      assert_redirected_to media_asset_path(@first, format: :json)
    end

    should "still render the listing when the search matches more than one and nothing bounds it" do
      get media_assets_path(redirect: true, search: { id: ">0", order: "id_asc" }), as: :json

      assert_response :success
      assert_equal([@first.id, @second.id], response.parsed_body.pluck("id").sort)
    end

    should "still redirect when the search matches exactly one" do
      get media_assets_path(redirect: true, search: { id: @second.id }), as: :json

      assert_response :redirect
      assert_redirected_to media_asset_path(@second, format: :json)
    end

    should "not redirect when redirect is absent, however the search is bounded" do
      get media_assets_path(limit: 1, search: { id: ">0", order: "id_asc" }), as: :json

      assert_response :success
    end
  end
end
