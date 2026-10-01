# Feeds LandingBlogCache a blog index without a network. Only the fetch is
# stubbed, at Danbooru::Http, so the real parse, projection and cache write run.
module LandingBlogHelper
  # The shape fourier-domain's tools/render-docs.py writes to blog/index.json.
  BLOG_INDEX = [
    { slug: "aggregating-a-community", title: "Aggregating a community.", date: "2026-06-07",
      lead: "Why every platform fails it.", author: "Saber",
      image: { src: "/blog/aggregating-a-community/cover.png", alt: "A crowd" },
      html: "/blog/aggregating-a-community.html", markdown: "/blog/aggregating-a-community.md" },
    { slug: "second-post", title: "Second.", date: "2026-05-01", lead: "Older.", author: "Saber", image: nil,
      html: "/blog/second-post.html", markdown: "/blog/second-post.md" },
  ].freeze

  def stub_blog_index(body, status: 200, content_type: "application/json", headers: {})
    body = body.to_json unless body.is_a?(String)
    response = HTTP::Response.new(status: status, body: body, version: "1.1", request: nil,
                                  headers: { "Content-Type" => content_type }.compact.merge(headers))
    Danbooru::Http.any_instance.stubs(:get).with(Danbooru.config.landing_blog_index_url).returns(response)
  end

  def seed_blog(index = BLOG_INDEX, now: Time.zone.now)
    stub_blog_index(index)
    LandingBlogCache.refresh!(now: now)
  end
end
