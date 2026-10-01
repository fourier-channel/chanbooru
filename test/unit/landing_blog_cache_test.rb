require "test_helper"

# The carousel's Blog row reads the blog's own index (fourier-domain's
# blog/index.json) in the background and serves the request from the cache.
class LandingBlogCacheTest < ActiveSupport::TestCase
  INDEX = LandingBlogHelper::BLOG_INDEX

  context "a refresh" do
    should "keep what a slide needs from each post, with its links made absolute" do
      assert_equal 2, seed_blog

      first, second = LandingBlogCache.posts
      assert_equal %i[author blurb date image image_alt slug title url], first.keys.sort
      assert_equal "aggregating-a-community", first[:slug]
      assert_equal "Aggregating a community.", first[:title]
      assert_equal "Saber", first[:author]
      assert_equal "Why every platform fails it.", first[:blurb]
      assert_equal "2026-06-07", first[:date]
      assert_equal "https://41chan.net/blog/aggregating-a-community.html", first[:url]
      assert_equal "https://41chan.net/blog/aggregating-a-community/cover.png", first[:image]
      assert_equal "A crowd", first[:image_alt]
      assert_nil second[:image], "a post with no picture is shown without one"
    end

    should "keep the posts in the blog's own order" do
      seed_blog(INDEX.reverse)
      assert_equal %w[second-post aggregating-a-community], LandingBlogCache.posts.pluck(:slug)
    end

    # Production served this shape until fourier-domain deployed the byline
    # and the picture, and the row must not depend on the order of deploys.
    should "show a post from an index that names no author and no picture" do
      seed_blog([INDEX[0].except(:author, :image)])

      post = LandingBlogCache.posts.sole
      assert_nil post[:author]
      assert_nil post[:image]
      assert_equal "Aggregating a community.", post[:title]
    end

    should "refuse a link or a picture that is not on the blog's own origin, and say so" do
      seed_blog([INDEX[0].merge(html: "https://elsewhere.example/x.html"),
                 INDEX[1].merge(image: { src: "javascript:alert(1)", alt: "" })])

      assert_equal %w[second-post], LandingBlogCache.posts.pluck(:slug)
      assert_nil LandingBlogCache.posts.sole[:image]
      problems = LandingBlogCache.status[:problems]
      assert(problems.any? { it.include?("aggregating-a-community") && it.include?("origin") }, problems.inspect)
      assert(problems.any? { it.include?("second-post") && it.include?("picture") }, problems.inspect)
    end

    should "skip a post it cannot show, name it, and keep the rest" do
      seed_blog([{ slug: "Bad Slug!", title: "x", html: "/blog/x.html" },
                 { slug: "untitled", html: "/blog/untitled.html" },
                 "not an object",
                 INDEX[1]])

      assert_equal %w[second-post], LandingBlogCache.posts.pluck(:slug)
      status = LandingBlogCache.status
      assert status[:ok]
      assert_equal 4, status[:listed]
      assert_equal 1, status[:count]
      assert_equal 3, status[:problems].size, status[:problems].inspect
    end

    should "cap the text it keeps" do
      seed_blog([INDEX[1].merge(title: "t" * 1_000, lead: "l" * 5_000, author: "a" * 500)])

      post = LandingBlogCache.posts.sole
      assert_operator post[:title].length, :<=, LandingBlogCache::MAX_TITLE
      assert_operator post[:blurb].length, :<=, LandingBlogCache::MAX_BLURB
      assert_operator post[:author].length, :<=, LandingBlogCache::MAX_AUTHOR
    end

    should "treat an index that lists nothing as an empty blog, not a failure" do
      assert_equal 0, seed_blog([])
      assert LandingBlogCache.status[:ok]
      assert_equal [], LandingBlogCache.posts
    end
  end

  # Every one of these keeps the last good read. A failed read replacing it
  # would blank the row for the length of the outage, which is the thing a
  # cache in front of another host is for.
  context "a failed refresh" do
    setup do
      seed_blog(now: 1.hour.ago)
    end

    should "keep serving the last good read, and record what failed" do
      stub_blog_index("oops", status: 500, content_type: "text/plain")

      error = assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }
      assert_match(/500/, error.message)
      assert_equal 2, LandingBlogCache.posts.size
      status = LandingBlogCache.status
      assert_not status[:ok]
      assert_equal error.message, status[:error]
    end

    should "treat a body that is not JSON as a failure, not as an empty blog" do
      stub_blog_index("<html>challenge</html>", content_type: "text/html")

      error = assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }
      assert_match(/not valid JSON/, error.message)
      assert_equal 2, LandingBlogCache.posts.size
    end

    should "treat JSON that is not a list as a failure" do
      stub_blog_index({ posts: [] })
      assert_match(/not a list/, assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }.message)
    end

    should "treat an index whose every post is unusable as a failure" do
      stub_blog_index([{ slug: "x" }])

      assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }
      assert_equal 2, LandingBlogCache.posts.size
    end

    should "treat an index of nothing but nulls as unusable, not as an empty blog" do
      stub_blog_index([nil, nil])

      assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }
      assert_equal 2, LandingBlogCache.posts.size
    end

    should "name a Cloudflare challenge when that is what answered" do
      stub_blog_index("<!DOCTYPE html><title>Just a moment...</title>", status: 403, content_type: "text/html")
      assert_match(/Cloudflare/, assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }.message)
    end

    should "name a timeout" do
      stub_blog_index("", status: 597, content_type: nil)
      assert_match(/timed out/, assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }.message)
    end

    should "not follow a redirect, and say where it pointed and what to change" do
      stub_blog_index("", status: 301, content_type: nil, headers: { "Location" => "https://41chan.net/blog/moved.json" })

      error = assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }
      assert_match(%r{https://41chan.net/blog/moved.json}, error.message)
      assert_match(/landing_blog_index_url/, error.message)
    end
  end

  context "the read path" do
    should "never fetch: a cold cache is an empty row and a job" do
      Danbooru::Http.any_instance.expects(:get).never

      assert_enqueued_with(job: LandingBlogRefreshJob) do
        assert_equal [], LandingBlogCache.posts
      end
    end

    should "ask for one refresh however many visitors find it cold" do
      assert_enqueued_jobs(1, only: LandingBlogRefreshJob) do
        3.times { LandingBlogCache.posts }
      end
    end

    should "serve a stale read at once and refresh it behind the visitor" do
      seed_blog(now: 10.minutes.ago)

      assert_enqueued_with(job: LandingBlogRefreshJob) do
        assert_equal 2, LandingBlogCache.posts.size
      end
    end

    should "not ask for a refresh while the read is fresh" do
      seed_blog

      assert_no_enqueued_jobs(only: LandingBlogRefreshJob) { LandingBlogCache.posts }
    end

    should "read a different entry when the index moves" do
      seed_blog
      Danbooru.config.stubs(:landing_blog_index_url).returns("https://example.net/blog/index.json")

      assert_equal [], LandingBlogCache.posts
    end
  end
end
