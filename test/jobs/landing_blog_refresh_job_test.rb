require "test_helper"

class LandingBlogRefreshJobTest < ActiveJob::TestCase
  context "LandingBlogRefreshJob" do
    should "read the blog's index into the cache" do
      stub_blog_index(LandingBlogHelper::BLOG_INDEX)

      LandingBlogRefreshJob.perform_now

      assert_equal 2, LandingBlogCache.posts.size
    end

    # Raised, not swallowed: the job queue is where a failed read is seen.
    should "fail when the read fails" do
      stub_blog_index("oops", status: 500, content_type: "text/plain")

      assert_raises(LandingBlogCache::Error) { LandingBlogRefreshJob.perform_now }
    end
  end
end
