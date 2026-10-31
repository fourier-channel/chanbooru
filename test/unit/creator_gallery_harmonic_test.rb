# frozen_string_literal: true

require "test_helper"

# A harmonic's link and the list it is judged by (CREATOR_TUNER.md rev 3,
# sec 5). The link cases live in a fixture that harmonic_model.js's test
# reads too, so the builder and Save cannot answer one paste two ways.
class CreatorGalleryHarmonicTest < ActiveSupport::TestCase
  CASES = JSON.parse(Rails.root.join("test/fixtures/files/harmonic_links.json").read)["cases"]

  context "A pasted link" do
    should "be answered as the shared cases say" do
      wrong = CASES.filter_map do |raw, expected|
        got = CreatorGalleryHarmonic.link(raw).deep_stringify_keys.slice(*expected.keys)
        "#{raw.inspect}: wanted #{expected}, got #{got}" unless got == expected
      end

      assert_empty(wrong, wrong.join("\n"))
    end

    should "come back the same when pasted again" do
      urls = CASES.filter_map { |_, expected| expected["url"] }

      assert(urls.size >= 10, "the fixture carries accepted links")
      assert_equal(urls, urls.map { |url| CreatorGalleryHarmonic.link(url)[:url] })
    end
  end

  context "The list" do
    should "carry the sites the operator chose, Fanbox gone" do
      assert_equal(21, CreatorGalleryHarmonic::SITES.size)
      assert_not(CreatorGalleryHarmonic::SITES.key?("fanbox"))
      assert(CreatorGalleryHarmonic::SITES.values.all? { |site| site.shape.start_with?("https://") })
    end

    should "draw each site's mark from a bundled logo, or none" do
      missing = CreatorGalleryHarmonic::SITES.values.filter_map(&:logo).reject { |logo| Rails.public_path.join("logos", logo).file? }

      assert_empty(missing)
    end

    should "accept every site's own example link" do
      wrong = CreatorGalleryHarmonic::SITES.values.reject { |site| CreatorGalleryHarmonic.link(site.shape)[:site] == site.key }

      assert_empty(wrong.map(&:key))
    end

    should "have a sentence for every refusal, naming only what it is given" do
      CreatorGalleryHarmonic::PROBLEMS.each do |key, words|
        vars = words.scan(/%\{(\w+)\}/).flatten.to_h { |name| [name.to_sym, "<#{name}>"] }

        assert_no_match(/%\{/, CreatorGalleryHarmonic.sentence(key, **vars), key)
      end
    end

    should "read the domain a small card keeps" do
      assert_equal("civitai.com", CreatorGalleryHarmonic.domain("www.civitai.com"))
      assert_equal("x.com", CreatorGalleryHarmonic.domain("x.com"))
    end
  end

  context "A stored harmonic" do
    setup do
      @gallery = create(:creator_gallery)
      @harmonic = @gallery.creator_gallery_harmonics.create!(site: "x", url: "https://x.com/duskmaker", title: "Dusk")
    end

    should "count while shown, listed, unhidden and not removed" do
      assert(@harmonic.counts?(Set.new))
      assert_not(@harmonic.counts?(Set["https://x.com/duskmaker"]))
      @harmonic.shown = false

      assert_not(@harmonic.counts?(Set.new))
    end

    should "stop counting, and tell its owner why, when staff hide it" do
      @harmonic.update!(staff_hidden_at: Time.zone.now, staff_hidden_reason: "spam")

      assert_not(@harmonic.counts?(Set.new))
      assert_equal("Harmonic 2 was hidden by site staff: spam. It is not shown on your page.", @harmonic.owner_notice(Set.new, 2))
    end

    should "stop counting while its site is off the list, and keep its row" do
      @harmonic.update!(site: "gone")

      assert_not(@harmonic.counts?(Set.new))
      assert_match(/taken off the Tuner's list/, @harmonic.owner_notice(Set.new, 1))
      assert(@harmonic.reload.persisted?)
    end

    should "name a removed link without its scheme" do
      assert_match("(x.com/duskmaker)", @harmonic.owner_notice(Set["https://x.com/duskmaker"], 1))
      assert_nil(@harmonic.owner_notice(Set.new, 1))
    end

    should "go with its gallery" do
      @gallery.destroy!

      assert_not(CreatorGalleryHarmonic.exists?(@harmonic.id))
    end
  end
end
