# frozen_string_literal: true

require "test_helper"

# The Creator Gallery page as drawn (CreatorGalleryComponent; the Creator
# Gallery rebuild, 2026-10-23): the hero band on the landing page's belt with
# every post marked for the blacklist, the minibands in the creator's layout,
# the locked cards past the tier's cut carrying nothing of the post, and the
# edit page -- the same page with the editor's draft and the page's own
# sections as panels.
class CreatorGalleryComponentTest < ViewComponent::TestCase
  def slide(id, tags)
    { id: id, url: "/posts/#{id}", src: "/sample/#{id}.jpg", thumb: "/preview/#{id}.jpg", kind: "image",
      tags: tags, rating: "g", flags: "", score: 3, uploader_id: 7, creator: nil }
  end

  def draw(**changes)
    {
      banner: nil,
      hero: { tags: [{ name: "landscape", category: "general" }, { name: "maple_(maple)", category: "character" }],
              slides: [slide(1, "landscape maple_(maple)"), slide(2, "landscape")] },
      minis: [{ tag: { name: "sky", category: "general" }, slides: [slide(3, "sky"), slide(4, "sky")] },
              { tag: { name: "sea", category: "general" }, slides: [] },
              { tag: nil, slides: [] }],
      locked_count: 0,
      owner_notices: [],
      tuner: { "enabled" => false, "placement" => "A" },
      harmonics: [],
    }.merge(changes)
  end

  def avatar = { name: "Maple", mxc: nil, url: nil, problem: nil }

  def render_gallery(viewer: @maple, **options)
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: viewer, avatar: avatar, can_edit: false, scan: nil, draw: draw, **options))
    end
  end

  setup do
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple, settings: { "layout" => "1-2" })
    CurrentUser.user = @maple
  end

  teardown do
    CurrentUser.user = nil
  end

  should "ride the hero band on the belt, a row per character, every post marked for the blacklist" do
    render_gallery

    config = JSON.parse(page.find("[data-modland]", visible: :all)["data-config"])
    assert_equal(["all", "c-maple_(maple)"], config["categories"].pluck("key"))
    assert_equal([1], config["categories"].second["slides"].pluck("id"))
    assert_css(".modland-tab", count: 2, visible: :all)
    assert_css(".modland-poolitem[data-id='1'][data-tags='landscape maple_(maple)'][data-rating='g'][data-uploader-id='7']", visible: :all)
    assert_css(".modland-poolitem", count: 2, visible: :all)
    assert_no_css("[data-editor]")
  end

  should "draw the layout's minibands, one tag each, their posts marked for the blacklist" do
    render_gallery

    assert_css(".modcreator-minis-row", count: 2)
    assert_css(".modcreator-mini", count: 3)
    assert_css("[data-cg-mini='0'] a.modcreator-mini-item.mod-blacklist-target[data-id='3'][data-tags='sky']")
    assert_css("[data-cg-mini='0'] .modcreator-mini-dot", count: 2)
    # The editor names the tag in its own select: the label is hidden while
    # editing, as text a control replaces is (.modcreator-static).
    assert_css("[data-cg-mini='0'] .modcreator-mini-label.modcreator-static", text: "sky")
    assert_css("[data-cg-mini='1'] .modcreator-mini-empty", text: "No posts here for you yet")
    assert_css("[data-cg-mini='2'] .modcreator-mini-empty", text: "Nothing here yet")
  end

  should "put no belt on a band with no posts" do
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil, draw: draw(hero: { tags: [], slides: [] })))
    end

    assert_css("[data-modland][hidden]", visible: :all)
    assert_css(".modcreator-hero-empty")
  end

  should "mark the banner for the blacklist on both layers, and paint the token ground without one" do
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil, draw: draw(banner: slide(9, "sky"))))
    end
    assert_css(".modcreator-ground.mod-blacklist-target[data-id='9'][data-tags='sky'] img.modcreator-ground-art", visible: :all)
    assert_css(".modcreator-banner.mod-blacklist-target[data-id='9'] img.modcreator-banner-art", visible: :all)

    render_gallery
    assert_css(".modcreator-ground-art--none", visible: :all)
    assert_no_css(".modcreator-ground.mod-blacklist-target", visible: :all)
  end

  should "draw the locked cards empty, with nothing of the post" do
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil, draw: draw(locked_count: 3)))
    end

    assert_css(".modcreator-more-count", text: "3 more posts in this gallery")
    assert_css(".modcreator-card--locked", count: 3, visible: :all)
    assert_no_css(".modcreator-card--locked *, .modcreator-card--locked[data-id]", visible: :all)
  end

  should "offer Edit Gallery to the creator and Sign in with Matrix to everyone else" do
    render_gallery(can_edit: true)
    assert_link("Edit Gallery", href: "/creators/maple/edit")

    render_gallery
    assert_no_link("Edit Gallery")
    assert_link("Sign in with Matrix")
  end

  context "with the Tuner" do
    setup do
      @card = { id: 11, number: 1, shown: true, counts: true, url: "https://bsky.app/profile/maple.bsky.social", host: "bsky.app",
                domain: "bsky.app", site: "bluesky", name: "Bluesky", logo: nil, support: false, adult: false, title: "Daily sketches",
                subtitle: "", cta: nil, cta_label: nil, places: { "mark" => "tl", "title" => "bl", "subtitle" => "bl", "button" => "br", "host" => "tr" },
                gradient: 1, picture: nil }
    end

    should "draw A in the id row across from the name, with the leaving notice" do
      render_gallery(draw: draw(tuner: { "enabled" => true, "placement" => "A" }, harmonics: [@card]))

      assert_css("header.modcreator-head.modcreator-head--dial .modcreator-id.modcreator-id--tuned > section.cg-tuner--a a.cg-hm")
      assert_no_css(".cg-tuner--b")
      assert_css("dialog.cg-leave[data-cg-leave]", visible: :all)
      assert_css("dialog.cg-leave button[value='stay'][autofocus]", visible: :all)
    end

    should "draw B in the banner's place, the banner grown to hold it" do
      render_gallery(draw: draw(tuner: { "enabled" => true, "placement" => "B" }, harmonics: [@card]))

      assert_css("header.modcreator-head--sky > section.cg-tuner--b a.cg-hm")
      assert_no_css(".modcreator-id--tuned, .cg-tuner--a")
    end

    should "draw no Tuner, card or notice while it is off, with no card to draw, or on a page closed to the viewer" do
      [draw(harmonics: [@card]), draw(tuner: { "enabled" => true, "placement" => "A" }, harmonics: [])].each do |drawn|
        render_gallery(draw: drawn)
        assert_no_css(".cg-tuner, .cg-hm, dialog.cg-leave, .modcreator-head--dial, .modcreator-head--sky", visible: :all)
      end

      render_gallery(closed: true, draw: draw(tuner: { "enabled" => true, "placement" => "B" }, harmonics: [@card]))
      assert_no_css(".cg-tuner, .cg-hm, dialog.cg-leave", visible: :all)
    end
  end

  context "editing" do
    setup do
      palette = [{ name: "landscape", category: "general", count: 12 }, { name: "sky", category: "general", count: 4 }]
      panels = { "Blog messages" => "<form id='blog-form'></form>".html_safe }
      create(:tag, name: "maple_(maple)", category: Tag.categories.character)
      @stored = Array.new(3) { as(@maple) { create(:post) } }
      # The draw is the curator's own: a stored post or a band tag hidden from
      # them is not in it, and the editor still starts from what is stored.
      @gallery.update!(settings: { "layout" => "1-2", "hero" => { "tags" => %w[landscape maple_(maple) veiled] }})
      [["hero", @stored[0]], ["hero", @stored[1]], ["mini1", @stored[2]]].each_with_index do |(band, post), i|
        @gallery.creator_gallery_posts.create!(band: band, post: post, position: i)
      end
      with_request_url "/creators/maple" do
        render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: true, editing: true, scan: nil,
                                                  draw: draw(banner: slide(9, "sky")), palette: palette, panels: panels))
      end
    end

    should "start the editor from the saved look and the bands' stored posts, not the curator's draw" do
      data = JSON.parse(page.find("[data-editor]")["data-editor"])

      assert_equal([{ "name" => "landscape", "category" => "general" }, { "name" => "maple_(maple)", "category" => "character" },
                    { "name" => "veiled", "category" => "general" }], data["draft"]["hero"]["tags"])
      assert_equal([@stored[0].id, @stored[1].id], data["draft"]["hero"]["posts"])
      assert_equal("1-2", data["draft"]["layout"])
      assert_equal([[@stored[2].id], [], []], data["draft"]["minis"].pluck("posts"))
      assert_equal([1, 2, 3, 4, 9], data["slides"].pluck("id"))
      assert_equal(["landscape", "sky"], data["palette"].pluck("name"))
      assert_equal("/creators/maple/edit.json", data["candidatesUrl"])
      assert_equal("/creators/maple", data["saveUrl"])
    end

    should "draw the editor's bar and the page's own sections as panels" do
      assert_css(".modcreator.is-editing")
      assert_css("[data-cg-act='save'][disabled]")
      assert_css("[data-cg-sheet='page']", visible: :all)
      assert_css("[data-cg-sheet='layout'] [data-cg-act='layout']", count: CreatorGalleryLayout::LAYOUTS.size, visible: :all)
      assert_css("[data-cg-panel][data-cg-title='Blog messages'] #blog-form", visible: :all)
      # Discard reloads the page; a field the browser refilled would show what was discarded.
      assert_no_css("[data-cg-field]:not([autocomplete='off'])", visible: :all)
      assert_no_link("Edit Gallery")
    end
  end
end
