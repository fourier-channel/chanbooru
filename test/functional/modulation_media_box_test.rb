# frozen_string_literal: true

require "test_helper"

# THE CENTRE'S BOX. The post view's stage had no height of its own: the centre
# shrink-wrapped an <img> whose CSS cancelled its width/height attributes, so
# until the bytes arrived the stage was its frame's 2px border, the flank
# columns (stretched to it) masked every thumbnail away, and the tag panel rode
# up by the image's height and back down when it landed (operator, 2026-10-18).
#
# So the payload names the box: the exact size of the rendition it points the
# centre at. That has to be the rendition PRODUCTION serves -- the gate snaps
# the sample's ?w=850 to the 720x720 webp (fourier-auth booru-media.js
# pickVariant) -- so a post with a sample is pointed at the 720 variant
# directly, and its box is that variant's size. w/h stay the original's: the
# fullscreen viewer fits the original by them.
class ModulationMediaBoxTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = create(:user)
    @uploader = create(:user)
  end

  def make(ext, width, height, duration: nil, source: "")
    as(@uploader) do
      create(:post, file_ext: ext, image_width: width, image_height: height, tag_string: "boxq", source: source,
                    media_asset: build(:media_asset, file_ext: ext, image_width: width, image_height: height, duration: duration))
    end
  end

  def media(post, viewer = @viewer)
    as(viewer) { ModulationPostComponent.new(post: post, viewer: viewer).payload[:media] }
  end

  context "the payload's media" do
    should "point a post with a sample at the 720 rendition, boxed at that rendition's size" do
      post = make("jpg", 2000, 3000)
      assert post.media_asset.has_variant?(:sample), "fixture: a static image wider than 850 has a sample"

      m = media(post)
      assert_equal "image", m[:kind]
      assert_equal post.media_asset.variant(:"720x720").file_url, m[:src]
      assert_equal [480, 720], m[:box]
      assert_equal [2000, 3000], [m[:w], m[:h]], "w/h stay the original's, for the fullscreen fit"
    end

    should "box a landscape post with a sample at its 720 rendition too" do
      m = media(make("jpg", 3000, 2000))
      assert_equal [720, 480], m[:box]
    end

    # A Matrix-sourced post is served by another route: the gate's /media route
    # keeps a ?width=850 request at 850 and serves the 850 sample (fourier-auth
    # mediar2.js booruVariantKey), so the 720 would be a smaller, softer picture
    # than it showed before. It keeps its sample, boxed at the sample's size.
    should "point a Matrix-sourced post with a sample at its sample, boxed at the sample's size" do
      post = make("jpg", 2000, 3000, source: "mxc://example.org/AbCdEf")
      sample = post.media_asset.variant(:sample)

      m = media(post)
      assert_equal sample.file_url, m[:src]
      assert_equal [sample.width, sample.height], m[:box]
      assert_equal [850, 1275], m[:box]
    end

    should "point a post without a sample at its original, boxed at the original's size" do
      post = make("png", 600, 400)
      assert_not post.media_asset.has_variant?(:sample), "fixture: 600 wide has no sample"

      m = media(post)
      assert_equal post.media_asset.variant(:original).file_url, m[:src]
      assert_equal [600, 400], m[:box]
    end

    # The 720 rendition of an animated gif is a still webp: the original is
    # what plays.
    should "point an animated gif at its original" do
      post = make("gif", 2000, 3000, duration: 2.5)
      assert_not post.media_asset.has_variant?(:sample), "fixture: an animated image has no sample"

      m = media(post)
      assert_equal post.media_asset.variant(:original).file_url, m[:src]
      assert_equal [2000, 3000], m[:box]
    end

    should "box a video at its own size" do
      post = make("mp4", 1280, 720, duration: 4.0)

      m = media(post)
      assert_equal "video", m[:kind]
      assert_equal post.file_url, m[:src]
      assert_equal post.preview_file_url, m[:poster]
      assert_equal [1280, 720], m[:box]
    end

    # Ugoira and the rest show their 180 preview and a link out.
    should "box an ugoira at its 180 preview's size" do
      post = make("zip", 2000, 3000)

      m = media(post)
      assert_equal "other", m[:kind]
      assert_equal post.preview_file_url, m[:src]
      assert_equal [120, 180], m[:box]
    end

    should "give flash no box: its preview is a fixed placeholder of no known size" do
      m = media(make("swf", 640, 480))
      assert_equal "other", m[:kind]
      assert_nil m[:box]
    end

    should "give a post whose picture the viewer may not see no src and no box" do
      post = make("jpg", 2000, 3000)
      post.update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations -- an artist ban, as the moderation flag sets it
      assert_not post.visible?(@viewer), "fixture: a banned post's picture is not a member's"

      m = media(post)
      assert_nil m[:src]
      assert_nil m[:box]
    end
  end

  # The box exists before the script runs: the server writes it onto the
  # centre, so a cold load paints the stage at its final size.
  context "the rendered centre" do
    should "carry the payload's box as its style" do
      post = make("jpg", 2000, 3000)
      get_auth post_path(post, preset: "modulation"), @viewer
      assert_response :success

      payload = JSON.parse(css_select(".modulation").first["data-payload"])
      centre = css_select(".mod-stage-center").first
      assert_equal [480, 720], payload.dig("media", "box")
      assert_equal "--mod-bw:480;--mod-bh:720", centre["style"]
    end

    should "carry no style when there is no box" do
      post = make("swf", 640, 480)
      get_auth post_path(post, preset: "modulation"), @viewer
      assert_response :success

      assert_nil css_select(".mod-stage-center").first["style"]
    end
  end
end
