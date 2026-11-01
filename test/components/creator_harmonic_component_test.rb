# frozen_string_literal: true

require "test_helper"

# A harmonic as the Tuner draws it (CreatorHarmonicComponent; CREATOR_TUNER.md
# rev 3, sec 2 and 5): one anchor out, opened in a new context with nothing
# of the booru sent along, nothing in it loaded from the site it names, and
# its words in the rows its places make. The Tuner around it is
# creator_tuner_component_test.rb's.
class CreatorHarmonicComponentTest < ViewComponent::TestCase
  PRESETS = CreatorGalleryHarmonic::CONFIG["presets"].to_h { |key, _label, places| [key, places] }

  def card(**changes)
    {
      id: 11, number: 1, shown: true, counts: true, url: "https://bsky.app/profile/maple.bsky.social", host: "bsky.app",
      domain: "bsky.app", site: "bluesky", name: "Bluesky", logo: "bluesky-logo.png", support: false, adult: true,
      title: "Daily sketches", subtitle: "Mostly maple leaves", cta: "follow", cta_label: "Follow",
      places: PRESETS["corner"], gradient: nil, picture: nil, notice: nil,
    }.merge(changes)
  end

  def picture(**changes)
    { id: 5, tags: "maple_(maple) sky", rating: "g", flags: "", score: 3, uploader_id: 7, w: 1600, h: 1000,
      src: "/sample/5.jpg", focus_x: 30, focus_y: 60, zoom: 150, shade: 10 }.merge(changes)
  end

  def render_card(hidden: false, **changes)
    render_inline(CreatorHarmonicComponent.new(card: card(**changes), hidden: hidden))
  end

  context "a harmonic" do
    should "be one anchor to the link, in a new context that carries nothing of the booru" do
      render_card

      assert_css("a.cg-hm", count: 1)
      link = page.find("a.cg-hm")
      assert_equal("https://bsky.app/profile/maple.bsky.social", link["href"])
      assert_equal("_blank", link["target"])
      assert_equal(%w[external noopener noreferrer nofollow ugc], link["rel"].split)
      assert_equal("Daily sketches, bsky.app", link["aria-label"])
      assert_equal("true", link["data-adult"])
    end

    should "load nothing from the site it names: the link is the only address off the booru" do
      render_card(picture: picture)

      addresses = page.all("[src], [href], [srcset]", visible: :all).flat_map { |node| [node["src"], node["href"], node["srcset"]] }.compact
      assert_equal(["https://bsky.app/profile/maple.bsky.social"], addresses.grep(/bsky/))
      assert_equal(["https://bsky.app/profile/maple.bsky.social"], page.all("[href]", visible: :all).pluck("href"))
      assert(page.all("[src]", visible: :all).all? { |node| node["src"].start_with?("/") })
    end

    should "draw the background post marked for the blacklist, framed where the creator set it, under its shade floor" do
      render_card(picture: picture)

      img = page.find("img.cg-hm-img.mod-blacklist-target", visible: :all)
      assert_equal("5", img["data-id"])
      assert_equal("maple_(maple) sky", img["data-tags"])
      assert_includes(img["style"], "object-position: 30% 60%")
      assert_includes(img["style"], "scale(1.5)")
      assert_includes(page.find(".cg-hm-shade", visible: :all)["style"], "opacity: 0.35")
      assert_no_css(".cg-hm-grad", visible: :all)
    end

    # The post's applied view (item 8), about the card's centre, then the
    # card's own focus and zoom; the style is the one creator_tuner.js draws
    # for the builder (test/fixtures/files/post_views.json).
    should "draw the background post under its applied view, composed with the card's focus and zoom" do
      render_card(picture: picture(view: { flip_h: true, flip_v: false, x: 100, y: 0, scale: 1000, stretch: 1200 }))

      assert_equal("object-position: 30% 60%; transform-origin: 30% 60%; transform: translate(20%, -10%) translate(10%, 0%) scale(-1.2, 1) translate(-20%, 10%) scale(1.5)",
                   page.find("img.cg-hm-img", visible: :all)["style"])

      render_card(picture: picture(view: nil))
      assert_equal("object-position: 30% 60%; transform-origin: 30% 60%; transform: scale(1.5)", page.find("img.cg-hm-img", visible: :all)["style"])
    end

    should "draw a gradient with nothing of any post when there is no picture to draw" do
      render_card(gradient: 2)

      assert_css(".cg-hm-grad--2", visible: :all)
      assert_no_css("img.cg-hm-img, [data-id], [data-tags]", visible: :all)
      assert_includes(page.find(".cg-hm-shade", visible: :all)["style"], "opacity: 0")
    end

    should "draw the bundled logo as it is, and a letter plate for a site with none" do
      render_card
      assert_css(".cg-hm-mark i img[src*='bluesky-logo']", visible: :all)

      render_card(logo: nil, name: "Ko-fi")
      assert_no_css(".cg-hm-mark img", visible: :all)
      assert_css(".cg-hm-mark i", text: "K", visible: :all)
    end

    should "leave out what has no words and a mark with no place" do
      render_card(subtitle: "", cta: nil, cta_label: nil, places: PRESETS["corner"].merge("mark" => ""))

      assert_no_css(".cg-hm-sub, .cg-hm-cta, .cg-hm-mark", visible: :all)
      assert_css(".cg-hm-safe--full .cg-hm-title", text: "Daily sketches", visible: :all)
      assert_css(".cg-hm-safe--full .cg-hm-host", text: "bsky.app", visible: :all)
    end

    should "draw a compact tier of the mark, the title and the host" do
      render_card

      assert_css(".cg-hm-safe--compact .cg-hm-mark", visible: :all)
      assert_css(".cg-hm-safe--compact .cg-hm-title", visible: :all)
      assert_css(".cg-hm-safe--compact .cg-hm-host", visible: :all)
      assert_no_css(".cg-hm-safe--compact .cg-hm-sub, .cg-hm-safe--compact .cg-hm-cta", visible: :all)
    end

    should "split a row holding a centre and a side place into thirds, and keep any other row as it is" do
      component = CreatorHarmonicComponent.new(card: card(places: PRESETS["centre"].merge("host" => "br")))
      bottom = component.rows("full").assoc("b")
      assert_equal(true, bottom[1])
      assert_equal([["l", []], ["c", ["button"]], ["r", ["host"]]], bottom[2])

      split = CreatorHarmonicComponent.new(card: card(places: PRESETS["split"]))
      middle = split.rows("full").assoc("m")
      assert_equal(false, middle[1])
      assert_equal([["l", %w[title subtitle]], ["r", ["button"]]], middle[2])
      assert_equal([["l", ["host"]]], split.rows("full").assoc("b")[2])
    end

    should "be dimmed for its owner when visitors do not see it, amber with the reason when there is something to fix" do
      render_card(shown: false)
      assert_css("a.cg-hm.cg-hm--off")
      assert_no_css("a.cg-hm--amber")

      render_card(counts: false, notice: "Harmonic 1's background is no longer one of your posts.")
      assert_css("a.cg-hm.cg-hm--off.cg-hm--amber[title=\"Harmonic 1's background is no longer one of your posts.\"]")
    end

    should "be out of sight and the tab order when it is not the card the Tuner shows" do
      render_card(hidden: true)
      assert_css("a.cg-hm[hidden]", visible: :all)
    end
  end
end
