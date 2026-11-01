# frozen_string_literal: true

require "test_helper"

# The Tuner (CreatorTunerComponent; CREATOR_TUNER.md rev 3, sec 7) in both
# placements. A's stations carry each site's bundled logo on a plate, or its
# letter where the site has none (operator, 2026-11-01); its static is drawn
# on a canvas alone; and nothing in a Tuner loads from off the booru: each
# card's link is the only address that leaves it (sec 5.2).
class CreatorTunerComponentTest < ViewComponent::TestCase
  PRESETS = CreatorGalleryHarmonic::CONFIG["presets"].to_h { |key, _label, places| [key, places] }

  def card(**changes)
    {
      id: 11, number: 1, shown: true, counts: true, url: "https://bsky.app/profile/maple.bsky.social", host: "bsky.app",
      domain: "bsky.app", site: "bluesky", name: "Bluesky", logo: "bluesky-logo.png", support: false, adult: true,
      title: "Daily sketches", subtitle: "Mostly maple leaves", cta: "follow", cta_label: "Follow",
      places: PRESETS["corner"], gradient: nil, picture: nil, notice: nil,
    }.merge(changes)
  end

  def faceless(**changes)
    card(id: 12, url: "https://huggingface.co/maple", host: "huggingface.co", domain: "huggingface.co", site: "huggingface",
         name: "Hugging Face", logo: nil, title: "Models", **changes)
  end

  def picture(**changes)
    { id: 5, tags: "maple_(maple) sky", rating: "g", flags: "", score: 3, uploader_id: 7, w: 1600, h: 1000,
      src: "/sample/5.jpg", focus_x: 30, focus_y: 60, zoom: 150, shade: 10 }.merge(changes)
  end

  def render_tuner(placement, cards, scan: nil)
    render_inline(CreatorTunerComponent.new(placement: placement, cards: cards, scan: scan))
  end

  context "A, the Masthead Dial" do
    should "draw a card over a station scale, a needle and a knob, the first card shown" do
      render_tuner("A", [card, card(id: 12, name: "Pixiv", logo: "pixiv-logo.png", title: "Works")])

      assert_css("section.cg-tuner.cg-tuner--a[data-cg-tuner='A'][data-scan='']")
      assert_css(".cg-tuner-slot a.cg-hm", count: 1)
      assert_css(".cg-tuner-slot a.cg-hm[hidden]", count: 1, visible: :all)
      assert_css(".cg-tuner-station", count: 2, visible: :all)
      assert_css(".cg-tuner-station.is-on[data-station='Bluesky: Daily sketches']", count: 1, visible: :all)
      knob = page.find(".cg-tuner-knob[role='slider']")
      assert_equal(%w[0 1 2 1 Bluesky:], [knob["tabindex"], knob["aria-valuemin"], knob["aria-valuemax"], knob["aria-valuenow"], knob["aria-valuetext"].split.first])
      assert_equal("true", page.find("[data-cg-scan]")["aria-pressed"])
    end

    should "mark a station with its site's bundled logo, and with its letter where the site has none" do
      render_tuner("A", [card, faceless])

      logo, letter = page.all(".cg-tuner-station b", visible: :all).to_a
      mark = logo.find("img", visible: :all)
      assert_match(%r{\A/.*bluesky-logo.*\.png\z}, mark["src"])
      assert_equal("", mark["alt"])
      assert_equal("", logo.text(:all).strip)
      assert_equal("H", letter.text(:all).strip)
      assert_equal(false, letter.has_css?("img", visible: :all))
    end

    should "draw its static on a canvas alone, with no scanline layer" do
      render_tuner("A", [card])

      assert_css(".cg-tuner-slot canvas.cg-tuner-static[aria-hidden='true']", visible: :all)
      assert_no_css(".cg-tuner-scanlines", visible: :all)
    end

    should "load nothing from off the booru: each card's link is the only address that leaves it" do
      render_tuner("A", [card(picture: picture), faceless(picture: picture(id: 6, src: "/sample/6.jpg")), card(id: 13, logo: "pixiv-logo.png", url: "https://www.pixiv.net/users/1", host: "pixiv.net")])

      values = Nokogiri::HTML5.fragment(rendered_content).xpath(".//@*").map(&:value)
      assert_equal(["https://bsky.app/profile/maple.bsky.social", "https://huggingface.co/maple", "https://www.pixiv.net/users/1"],
                   values.grep(%r{//|url\(}i))
      assert_css(".cg-tuner-station b img", count: 2, visible: :all)
      assert(page.all("[src]", visible: :all).all? { |node| node["src"].start_with?("/") && !node["src"].start_with?("//") })
    end
  end

  context "B, the Skywave Dial" do
    should "draw a card in a panel, with previous, a pip a card, Scan and next" do
      render_tuner("B", [card, card(id: 12, title: "Works")], scan: false)

      assert_css("section.cg-tuner--b[data-scan='false'] .cg-tuner-panel .cg-tuner-slot a.cg-hm", count: 1)
      assert_css(".cg-tuner-pip", count: 2)
      assert_css(".cg-tuner-pip[aria-current='true'][aria-label='Harmonic 1 of 2: Daily sketches']")
      assert_css("[data-cg-step='-1'], [data-cg-step='1']", count: 2)
      assert_equal("false", page.find("[data-cg-scan]")["aria-pressed"])
      assert_no_css(".cg-tuner-knob, .cg-tuner-station, canvas", visible: :all)
    end
  end
end
