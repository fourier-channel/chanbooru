require "test_helper"

class LandingShowcaseRefreshJobTest < ActiveJob::TestCase
  context "LandingShowcaseRefreshJob" do
    setup do
      LandingCategory.create!(key: "featured", label: "Featured", kind: "tags", ordering: "new", tags: %w[alpha beta], position: 4)
      LandingCategory.create!(key: "favorites", label: "Favorites", kind: "tags", ordering: "favcount", tags: %w[gamma delta], position: 2)
    end

    # One row whose every search failed must not cost the other its refresh.
    should "refresh every row before reporting the one that failed" do
      LandingShowcaseCache.expects(:refresh!).twice.raises(LandingShowcaseCache::Error, "every search for the favorites row failed").then.returns(4)

      error = assert_raises(LandingShowcaseCache::Error) { LandingShowcaseRefreshJob.perform_now }
      assert_match(/favorites row failed/, error.message)
    end
  end
end
