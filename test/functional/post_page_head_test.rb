# frozen_string_literal: true

require "test_helper"

# The post page's head tags, under each interface (stage 1, step 7). The
# page is carved in two: upstream's app/views/posts/show for classic and
# Modulation's own in app/interfaces/modulation. The tags a search engine or a
# link preview reads -- title, description, canonical URL, the comments feed
# and the OpenGraph text built from them -- are set by both, the same; the
# post's own tags (its id, its notes, its image and the adult rating) only by
# classic, as before the carve. The parity recordings hold every byte; this
# names the tags, so a carve that drops one says which.
class PostPageHeadTest < ActionDispatch::IntegrationTest
  SHARED = [
    ["title", nil],
    ['meta[name="description"]', "content"],
    ['link[rel="canonical"]', "href"],
    ['link[rel="alternate"][type="application/atom+xml"]', "href"],
    ['meta[property="og:title"]', "content"],
    ['meta[property="og:description"]', "content"],
    ['meta[property="og:url"]', "content"],
  ].freeze

  def head_tags(preset)
    # The "created by" label is drawn at random; both pages draw the same one.
    srand(1)
    get_auth post_path(@post, preset: preset, preset_sticky: 0), @user
    assert_response(:success, "the #{preset} post page answered #{response.status}")
    SHARED.to_h do |selector, attribute|
      found = css_select("head #{selector}")
      assert_equal(1, found.size, "the #{preset} post page set #{found.size} #{selector}; fix: its posts/show sets the head tags both pages set")
      value = attribute ? found.first[attribute] : found.first.text
      # og:url is the URL asked for, and the two requests differ in their
      # preset parameter only.
      [selector, selector.include?("og:url") ? value.split("?").first : value]
    end
  end

  context "The post page's head" do
    setup do
      @user = create(:user)
      @post = as(@user) { create(:post, rating: "e", image_width: 1200, image_height: 900) }
      # The OpenGraph image is drawn only for a viewer who may see the image
      # (OpenGraphComponent): a general post, where an explicit one is not.
      @general = as(@user) { create(:post, rating: "g") }
    end

    should "carry the same title, description, canonical URL and feed under both interfaces" do
      classic = head_tags("historical")
      modulation = head_tags("modulation")

      assert_match(/\S/, classic["title"])
      assert(classic['meta[name="description"]'].start_with?("View this 1200x900 "), classic['meta[name="description"]'])
      assert(classic['link[rel="canonical"]'].end_with?("/posts/#{@post.id}"), classic['link[rel="canonical"]'])
      assert_includes(classic['link[rel="alternate"][type="application/atom+xml"]'], "post_id%5D=#{@post.id}")
      SHARED.map(&:first).each do |selector|
        assert_equal(classic[selector], modulation[selector], "Modulation's #{selector} differs from classic's; fix: app/interfaces/modulation/views/posts/show.html.erb sets it as app/views/posts/show.html.erb does")
      end
    end

    should "carry the post's id, notes, image and rating under classic" do
      get_auth post_path(@post, preset: "historical", preset_sticky: 0), @user

      assert_response :success
      fix = "fix: app/views/posts/show.html.erb's html_header sets it"
      assert_select('head meta[name="post-id"][content=?]', @post.id.to_s, { count: 1 }, "no post-id meta; #{fix}")
      assert_select('head meta[name="post-has-embedded-notes"]', { count: 1 }, "no embedded-notes meta; #{fix}")
      assert_select('head meta[name="rating"][content="adult"]', { count: 1 }, "no adult rating on an explicit post; #{fix}")

      get_auth post_path(@general, preset: "historical", preset_sticky: 0), @user

      assert_response :success
      assert_select('head meta[property="og:image"]', { count: 1 }, "no OpenGraph image on a general post; #{fix}")
      assert_select('head meta[name="rating"]', { count: 0 }, "a rating on a general post; #{fix} only for an explicit one")
    end
  end
end
