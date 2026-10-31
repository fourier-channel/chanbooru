# frozen_string_literal: true

require "test_helper"

# THE TUNER on the gallery's layout (CREATOR_TUNER.md rev 3, operator
# 2026-10-31): harmonics saved through the gallery's one Save, all or nothing
# and upserted by id, so an admin's hide survives the owner's Save; and drawn
# per viewer, a picture counting against the page's post limit and leaving no
# trace for a viewer who may not see it.
class CreatorGalleryTunerTest < ActiveSupport::TestCase
  MXID = "@maple:41chan.net"
  CORNER = CreatorGalleryHarmonic::CONFIG["presets"].first.last

  def post_with(tags, creator: MXID)
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags, rating: "g") }
    FourierPostCreator.create!(post: post, mxid: creator, recorded_by: @tunnel.id)
    post
  end

  def layout = CreatorGalleryLayout.new(@gallery.reload)

  def rows = @gallery.creator_gallery_harmonics.reload.to_a

  # A valid look over the setup's posts, carrying the Tuner and these harmonics.
  def look(harmonics, tuner)
    {
      "headline" => "After Hours", "subline" => "", "banner" => { "post_id" => nil, "y" => 40 }, "depth" => { "blur" => 20, "dim" => 40, "parallax" => 60 },
      "hero" => { "tags" => %w[night], "effect" => "depth", "dir" => "right", "hold" => 6, "cells" => 7, "posts" => @posts.map(&:id) },
      "layout" => "1-2",
      "minis" => [
        { "tag" => "rain", "effect" => "fade", "dir" => "up", "hold" => 4, "posts" => [@posts[0].id] },
        { "tag" => "snow", "effect" => "flip", "dir" => "down", "hold" => 7, "posts" => [@posts[1].id] },
        { "tag" => "night", "effect" => "slide", "dir" => "left", "hold" => 5, "posts" => [@posts[2].id] },
      ],
      "tuner" => tuner, "harmonics" => harmonics,
    }
  end

  def harmonic(**over)
    { "url" => "https://civitai.com/user/maple", "title" => "Maple LoRA", "subtitle" => "SDXL style, v3", "cta" => "visit", "places" => CORNER,
      "background_gradient" => "1" }.merge(over.transform_keys(&:to_s))
  end

  def picture(post, **over)
    harmonic(background_gradient: nil, background_post_id: post.id, focus_x: 50, focus_y: 40, zoom: 120, shade: 45, **over)
  end

  def save(*harmonics, tuner: { "enabled" => true, "placement" => "A" })
    layout.save(viewer: @maple, page: {}, look: look(harmonics, tuner))
  end

  def hide(harmonic, reason = "spam")
    harmonic.update!(staff_hidden_at: Time.zone.now, staff_hidden_by: @admin, staff_hidden_reason: reason)
  end

  setup do
    @tunnel = create(:contributor_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: MXID, user: @maple)
    @posts = Array.new(6) { |i| post_with("night neon #{i.even? ? "rain" : "snow"}") }
  end

  context "Saving harmonics" do
    should "write the Tuner and the list in order, and keep each row's id when saved again" do
      assert_equal([], save(harmonic, picture(@posts[1], url: "https://x.com/maple", title: "On X")))

      assert_equal({ "enabled" => true, "placement" => "A" }, @gallery.reload.settings["tuner"])
      first, second = rows
      assert_equal(["civitai", "https://civitai.com/user/maple", 0, 1, nil], [first.site, first.url, first.position, first.background_gradient, first.zoom])
      assert_equal(["x", 1, @posts[1].id, 120, 45, nil], [second.site, second.position, second.background_post_id, second.zoom, second.shade, second.background_gradient])

      assert_equal([], save(harmonic(id: second.id, url: "https://x.com/maple", title: "X"), harmonic(id: first.id, title: "Models"), harmonic(url: "https://ko-fi.com/maple")))
      assert_equal([[second.id, "X", nil], [first.id, "Models", nil]], rows.first(2).map { |row| [row.id, row.title, row.background_post_id] })
      assert_equal(["kofi"], rows.drop(2).map(&:site))

      assert_equal([], save(harmonic(id: first.id)))
      assert_equal([first.id], rows.map(&:id))
      assert_equal([], save)
      assert_empty(rows)
    end

    should "leave the harmonics as they are when the look carries no list" do
      save(harmonic)

      assert_equal([], layout.save(viewer: @maple, page: {}, look: look(nil, nil).except("tuner", "harmonics")))
      assert_equal(1, rows.size)
      assert_equal({ "enabled" => true, "placement" => "A" }, @gallery.reload.settings["tuner"])
    end

    should "refuse the whole Save for one bad harmonic, naming each problem, and write nothing" do
      save(harmonic)
      before = rows.map(&:attributes)

      problems = save(harmonic(id: rows.first.id, title: "Renamed"), harmonic(url: "http://x.com/maple"), harmonic(url: "https://example.org/me", title: ""),
                      tuner: { "enabled" => false, "placement" => "C" })

      assert_equal([
        "The Tuner's placement \"C\" is not one of: A, B. Pick one of those.",
        "Harmonic 2's link uses http://. Use the https:// address of the same page.",
        "Harmonic 3's link is to example.org, which is not on the Tuner's list yet. Ask for it to be added, or link a site that is on the list.",
        "Harmonic 3's title is empty. Give it a title of up to 48 characters.",
      ], problems)
      assert_equal(before, rows.map(&:attributes))
      assert(@gallery.reload.settings["tuner"]["enabled"])
    end

    should "keep a staff-hidden harmonic through a Save that leaves it out and one that changes it" do
      save(harmonic, harmonic(url: "https://x.com/maple", title: "On X"))
      kept, hidden = rows
      hide(hidden)

      assert_equal([], save(harmonic(id: kept.id)))
      assert_equal([kept.id, hidden.id], rows.map(&:id))

      assert_equal([], save(harmonic(id: hidden.id, url: "https://x.com/other", title: "Changed"), harmonic(id: kept.id)))
      hidden.reload
      assert_equal([0, "https://x.com/maple", "On X", "spam", @admin], [hidden.position, hidden.url, hidden.title, hidden.staff_hidden_reason, hidden.staff_hidden_by])
    end

    should "hold the gallery to its cap of counting harmonics, raised by its owner's perk" do
      urls = %w[https://civitai.com/user/maple https://x.com/maple https://bsky.app/profile/maple.bsky.social https://pixiv.net/users/1
                https://deviantart.com/maple https://instagram.com/maple]
      six = urls.map { |url| harmonic(url: url) }

      assert_equal(["This gallery has 6 harmonics and holds 5. Remove one."], save(*six))
      assert_equal([], save(*six.first(5), six.last.merge("shown" => "false")))
      hide(rows.first)
      assert_equal([], save(*rows.drop(1).map { |row| harmonic(id: row.id, url: row.url) }))
      assert_equal(["This gallery has 6 harmonics and holds 5. Remove one."], save(*six))

      UserPerk.grant!(@maple, :creator_harmonic_cap, value: 6, by: @admin)
      assert_equal([], save(*six))
    end

    should "refuse a link staff removed, and a link under it" do
      CreatorHarmonicRemoval.create!(url: "https://civitai.com/user/maple", removed_by: @admin)

      assert_equal(["That link (civitai.com/user/Maple/models) was removed by site staff and cannot be added to any page. Remove it from your list, or write to staff if you think this was a mistake."],
                   save(harmonic(url: "https://civitai.com/user/Maple/models")))
    end

    should "refuse a removed link pasted in another spelling of the same page" do
      CreatorHarmonicRemoval.create!(url: "https://reddit.com/user/maple", removed_by: @admin)

      assert_equal(["That link (reddit.com/user/Maple) was removed by site staff and cannot be added to any page. Remove it from your list, or write to staff if you think this was a mistake."],
                   save(harmonic(url: "https://old.reddit.com/u/Maple/")))
    end

    should "refuse a background that is not one of the creator's showable posts" do
      stray = post_with("night", creator: "@alice:41chan.net")
      CreatorPostAudience.set!(@posts[3], gallery: @gallery, audience: "private", by: @maple)

      # @posts[3] is in the hero band too, so the band refuses it in its own words.
      assert_equal(["Post ##{@posts[3].id} cannot be chosen: its audience is private. Make it public on Who sees your posts, or take it off.",
                    "Harmonic 1's background is no longer one of your showable posts. Pick another, or a gradient.",
                    "Harmonic 2's background is no longer one of your showable posts. Pick another, or a gradient."],
                   save(picture(stray), picture(@posts[3], url: "https://x.com/maple")))
    end

    should "name the allowed values of every background setting it refuses" do
      assert_equal(["Harmonic 1 has both a picture and a gradient for its background. Pick one."], save(picture(@posts[0], background_gradient: "2")))
      assert_equal(["Harmonic 1's gradient \"7\" is not one of: 1 (Sea), 2 (Ember), 3 (Violet). Pick one of those."], save(harmonic(background_gradient: "7")))
      assert_equal([
        "Harmonic 1's zoom is 250; it runs from 100 to 200. Set it within that.",
        "Harmonic 1's shade is empty; it runs from 0 to 85. Set it within that.",
      ], save(picture(@posts[0], zoom: 250, shade: "")))
      assert_equal(["Harmonic 1's shade is 20%; over a picture it is at least 35%, so its words stay readable. Set it to 35 or more."], save(picture(@posts[0], shade: 20)))
    end

    should "name the allowed values of the words and places it refuses" do
      assert_equal([
        "Harmonic 1's title is 49 characters long. Shorten it to 48 or fewer.",
        "Harmonic 1's subtitle is 81 characters long. Shorten it to 80 or fewer.",
        "Harmonic 1's button word \"buy\" is not one of: visit, follow, download, view_model, support, join, commission. Pick one of those, or none.",
        "Harmonic 1's host place \"\" is not one of: tl, tc, tr, ml, mc, mr, bl, bc, br. Pick one of those.",
      ], save(harmonic(title: "t" * 49, subtitle: "s" * 81, cta: "buy", places: CORNER.except("host"))))
      assert_equal([], save(harmonic(cta: "", places: CORNER.except("mark"))))
      assert_equal({ "title" => "bl", "subtitle" => "bl", "button" => "br", "host" => "tr" }, rows.first.places)
    end

    # Sec 2.3: at 160 px a row holding a centre and a side place splits into
    # thirds, too narrow for a host to keep its domain.
    should "refuse a host that would be cut short at the smallest size, and take every preset" do
      assert_equal(["Harmonic 1's link host (civitai.com) shares its row with a centre and a side element, and at the smallest size it would be cut short. Move the host or one of the others to another row."],
                   save(harmonic(places: CORNER.merge("mark" => "bc", "host" => "br"))))
      CreatorGalleryHarmonic::CONFIG["presets"].each do |key, _, places|
        assert_equal([], save(harmonic(places: places)), key)
      end
    end

    should "refuse two links to the same page and a second support link" do
      assert_equal([
        "Harmonics 1 and 3 link to the same page. Remove one of them.",
        "Harmonic 4 links to Patreon, a support site, and harmonic 2 already links to Ko-fi. A gallery carries one support link: change or remove one of the two.",
      ], save(harmonic, harmonic(url: "https://ko-fi.com/maple"), harmonic(url: "https://civitai.com/user/maple/"), harmonic(url: "https://patreon.com/maple")))
    end

    should "refuse a harmonic that is not the gallery's, and more rows than it keeps" do
      other = create(:creator_gallery).creator_gallery_harmonics.create!(site: "x", url: "https://x.com/dusk", title: "Dusk", places: CORNER)

      assert_equal(["Harmonic 1 is not one of this gallery's harmonics. Reload the page and build it again."], save(harmonic(id: other.id)))
      assert_equal(["This gallery lists 31 harmonics, counting hidden ones, and keeps 30. Remove one."],
                   save(*Array.new(31) { |i| harmonic(url: "https://x.com/maple#{i}", shown: "false") }))
    end

    should "refuse one harmonic listed twice" do
      save(harmonic)

      assert_equal(["Harmonics 1 and 2 are the same harmonic, listed twice. Reload the page and build the list again."],
                   save(harmonic(id: rows.first.id), harmonic(id: rows.first.id.to_s, url: "https://x.com/maple")))
    end

    # Sec 4.6: the rows stay when a site leaves the list, so its return
    # restores them -- an unchanged link is not checked against the list again.
    should "keep a harmonic whose site left the list while its link is unchanged" do
      save(harmonic(url: "https://x.com/maple"))
      row = rows.first
      row.update_columns(site: "myspace") # rubocop:disable Rails/SkipsModelValidations -- a site the list no longer carries

      assert_equal([], save(harmonic(id: row.id, url: row.url, title: "Renamed")))
      assert_equal(%w[myspace Renamed], [row.reload.site, row.title])
      assert_equal(["Harmonic 1's link is to myspace.com, which is not on the Tuner's list yet. Ask for it to be added, or link a site that is on the list."],
                   save(harmonic(id: row.id, url: "https://myspace.com/maple")))
      assert_equal([], save(harmonic(id: row.id, url: "https://x.com/dusk")))
      assert_equal("x", row.reload.site)
    end
  end

  context "Drawing harmonics" do
    should "draw nothing for viewers while the Tuner is off, and every row for its manager" do
      save(harmonic, harmonic(url: "https://x.com/maple", shown: "false"), tuner: { "enabled" => "false", "placement" => "B" })

      assert_equal([], layout.draw(User.anonymous)[:harmonics])
      cards = layout.draw(User.anonymous, manager: true)[:harmonics]
      assert_equal([[1, true, true], [2, false, false]], cards.map { |card| [card[:number], card[:shown], card[:counts]] })
      assert_equal(["civitai.com", "Civitai", "civitai-logo.png", "Visit"], cards.first.values_at(:host, :name, :logo, :cta_label))
    end

    should "draw viewers the counting harmonics, and tell the owner why each other one is not drawn" do
      save(harmonic, harmonic(url: "https://x.com/maple"), harmonic(url: "https://bsky.app/profile/maple.bsky.social"), harmonic(url: "https://pixiv.net/users/1"))
      counting, hidden, removed, gone = rows
      hide(hidden)
      CreatorHarmonicRemoval.create!(url: removed.url, removed_by: @admin)
      gone.update_columns(site: "gone") # rubocop:disable Rails/SkipsModelValidations -- a site the list no longer carries

      assert_equal([[counting.id, nil]], layout.draw(User.anonymous)[:harmonics].map { |card| card.values_at(:id, :notice) })
      assert_equal([
        nil,
        "Harmonic 2 was hidden by site staff: spam. It is not shown on your page.",
        "That link (bsky.app/profile/maple.bsky.social) was removed by site staff and cannot be added to any page. Remove it from your list, or write to staff if you think this was a mistake.",
        "Harmonic 4's site was taken off the Tuner's list, so it is not shown and does not count. Its card comes back if the site does.",
      ], layout.draw(@admin)[:harmonics].pluck(:notice))
    end

    # Sec 6.3: a background is one of the posts the page shows. Cut after the
    # bands, so it never displaces a band's post; one already in a band costs
    # nothing more; past the cut the card draws on Ground, link intact.
    should "count pictures against the page's limit after the bands, and draw a cut one on Ground" do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(7)
      extra = Array.new(3) { post_with("night neon") }
      assert_equal([], save(*[@posts[0], @posts[1], *extra].each_with_index.map { |post, i| picture(post, url: "https://x.com/maple#{i}") }))

      drawn = layout.draw(User.anonymous)

      assert_equal(@posts.map(&:id), drawn[:hero][:slides].pluck(:id))
      assert_equal([@posts[0].id, @posts[1].id, extra[0].id, nil, nil], drawn[:harmonics].map { |card| card[:picture]&.fetch(:id) })
      assert_equal(["https://x.com/maple3", nil], drawn[:harmonics][3].values_at(:url, :gradient))
      assert_equal(0, drawn[:locked_count])
      assert_equal(5, layout.draw(@admin)[:harmonics].count { |card| card[:picture] })
    end

    should "name nothing of a picture the viewer may not see, and tell the owner it went stale" do
      save(picture(@posts[2]))
      assert_equal({ id: @posts[2].id, focus_x: 50, focus_y: 40, zoom: 120, shade: 45 }, layout.draw(User.anonymous)[:harmonics].first[:picture].slice(:id, :focus_x, :focus_y, :zoom, :shade))

      CreatorPostAudience.set!(@posts[2], gallery: @gallery, audience: "private", by: @maple)

      assert_nil(layout.draw(User.anonymous)[:harmonics].first[:picture])
      owner = layout.draw(User.anonymous, manager: true)[:harmonics].first
      assert_nil(owner[:picture])
      assert_equal("Harmonic 1's background is no longer one of your showable posts. Pick another, or a gradient.", owner[:notice])
    end
  end
end
