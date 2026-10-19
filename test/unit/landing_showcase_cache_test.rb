require "test_helper"

# The multi-creator rows' background searches (LandingShowcaseCache). One tag
# failing costs that creator one interval; EVERY tag failing must not replace
# the stored list with nothing.
class LandingShowcaseCacheTest < ActiveSupport::TestCase
  def creators_row
    LandingCategory.new(key: "featured", label: "Featured", kind: "tags", ordering: "new", tags: %w[alpha beta])
  end

  context "a refresh" do
    should "store what the searches found, one creator at a time" do
      PostQuery.any_instance.stubs(:posts_with_timeout).returns([stub(id: 7), stub(id: 9)], [stub(id: 8)])

      assert_equal 3, LandingShowcaseCache.refresh!(creators_row)
      assert_equal [7, 8, 9], LandingShowcaseCache.read(creators_row)[:ids]
    end

    should "keep the stored list when every search fails, and say so" do
      LandingShowcaseCache.write(creators_row, [1, 2, 3], 1.hour.ago)
      PostQuery.any_instance.stubs(:posts_with_timeout).raises(ActiveRecord::QueryCanceled, "canceling statement due to statement timeout")

      error = assert_raises(LandingShowcaseCache::Error) { LandingShowcaseCache.refresh!(creators_row) }
      assert_match(/every search/, error.message)
      assert_equal [1, 2, 3], LandingShowcaseCache.read(creators_row)[:ids]
    end

    # Each creator's search is the hero band's, so exempt from the browsing
    # tier (TIER_EXEMPT): run as anonymous, it would otherwise find the
    # viewer's page of posts, not PER_TAG.
    should "find PER_TAG posts a creator whatever the browsing cap" do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(2)
      user = create(:user)
      ids = as(user) { Array.new(LandingShowcaseCache::PER_TAG) { create(:post, tag_string: "alpha", rating: "g") } }.map(&:id)

      LandingShowcaseCache.refresh!(creators_row)
      assert_equal ids.sort, LandingShowcaseCache.read(creators_row)[:ids].sort
    end

    should "store the rest when only one search fails" do
      PostQuery.any_instance.stubs(:posts_with_timeout).raises(ActiveRecord::QueryCanceled).then.returns([stub(id: 8)])

      assert_equal 1, LandingShowcaseCache.refresh!(creators_row)
      assert_equal [8], LandingShowcaseCache.read(creators_row)[:ids]
    end
  end
end
