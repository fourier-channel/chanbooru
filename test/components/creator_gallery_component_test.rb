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

  def avatar = { name: "Maple Woods", mxc: nil, url: nil, problem: nil }

  def render_gallery(viewer: @maple, **options)
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: viewer, avatar: avatar, can_edit: false, scan: nil, draw: draw, **options))
    end
  end

  setup do
    @maple = create(:user, name: "maple_leaf")
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

  should "draw the banner full size on both layers, and a miniband from the sample" do
    minis = [{ tag: { name: "sky", category: "general" }, slides: [slide(3, "sky").merge(full: "/original/3.jpg")] },
             { tag: nil, slides: [] }, { tag: nil, slides: [] }]
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil,
                                                draw: draw(banner: slide(9, "sky").merge(full: "/original/9.jpg"), minis: minis)))
    end
    assert_css("img.modcreator-ground-art[src='/original/9.jpg']", visible: :all)
    assert_css("img.modcreator-banner-art[src='/original/9.jpg']", visible: :all)
    assert_css("img.modcreator-mini-img[src='/sample/3.jpg']", visible: :all)
  end

  should "carry each post's applied view: the ground's and banner's with the parallax, a miniband picture's on its img" do
    view = { flip_h: true, flip_v: false, x: 0, y: -50, scale: 900, stretch: 1000 }
    minis = [{ tag: { name: "sky", category: "general" }, slides: [slide(3, "sky").merge(view: view), slide(4, "sky").merge(view: nil)] },
             { tag: nil, slides: [] }, { tag: nil, slides: [] }]
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil,
                                                draw: draw(banner: slide(9, "sky").merge(view: view), minis: minis)))
    end

    expected = "--cg-view: translate(0%, -5%) scale(-0.9, 0.9)"
    [".modcreator-ground", ".modcreator-banner"].each do |layer|
      style = page.find(layer, visible: :all)["style"]
      assert_includes(style, "--cg-par: ")
      assert_includes(style, expected)
    end
    # On the picture, never the item the miniband's effect moves.
    assert_equal(expected, page.find("a[data-id='3'] img.modcreator-mini-img", visible: :all)["style"])
    assert_nil(page.find("a[data-id='3']", visible: :all)["style"])
    assert_nil(page.find("a[data-id='4'] img.modcreator-mini-img", visible: :all)["style"])
    # The art composes the view after the parallax's own move, inside one transform.
    scss = Rails.root.join("app/components/creator_gallery_component/creator_gallery_component.scss").read
    assert_match(/transform: translate3d\([^;]*var\(--cg-par\)[^;]*\) var\(--cg-view,\) scale\(1\.18\);/, scss)
    assert_match(/transform: translate3d\([^;]*var\(--cg-par\)[^;]*\) var\(--cg-view,\) scale\(1\.06\);/, scss)
    assert_match(/\.modcreator-mini-img \{[^}]*transform: var\(--cg-view, none\);/, scss)
  end

  should "carry no view on a page whose posts have none" do
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil, draw: draw(banner: slide(9, "sky").merge(view: nil))))
    end

    assert_not_includes(page.find(".modcreator-ground", visible: :all)["style"], "--cg-view")
    assert_not_includes(page.find(".modcreator-banner", visible: :all)["style"], "--cg-view")
    assert_nil(page.find("a[data-id='3'] img.modcreator-mini-img", visible: :all)["style"])
  end

  should "draw the locked cards empty, with nothing of the post" do
    with_request_url "/creators/maple" do
      render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar, can_edit: false, scan: nil, draw: draw(locked_count: 3)))
    end

    assert_css(".modcreator-more-count", text: "3 more posts in this gallery")
    assert_css(".modcreator-card--locked", count: 3, visible: :all)
    assert_no_css(".modcreator-card--locked *, .modcreator-card--locked[data-id]", visible: :all)
  end

  should "offer Edit Gallery to the creator as a pencil at the header's top right, and Sign in with Matrix to everyone else" do
    render_gallery(can_edit: true)
    assert_link("Edit Gallery", href: "/creators/maple/edit")
    assert_css("header.modcreator-head > a.modcreator-edit-btn[title='Edit Gallery'][href='/creators/maple/edit'] svg")
    assert_no_css(".modcreator-actions", visible: :all)

    render_gallery
    assert_no_link("Edit Gallery")
    assert_link("Sign in with Matrix")
  end

  # The creator's name under the title (operator, 2026-11-01): with the
  # contact on, one link -- the message icon and the Matrix ID, "Message on
  # Matrix" on hover; with it off, the same box with the creator's name alone,
  # and the Matrix ID nowhere on the page.
  context "the box under the title" do
    should "be a link to message the creator, with the icon and the Matrix ID, once the contact is on" do
      @gallery.update!(show_contact: true, matrix_contact: "@maple-work:41chan.net")
      render_gallery

      link = page.find(".modcreator-name h1.modcreator-title + a.modcreator-contact[href='https://matrix.to/#/@maple-work:41chan.net'][title='Message on Matrix']")
      assert_equal("@maple:41chan.net", link.find(".modcreator-contact-id").text)
      assert(link.has_css?("svg", visible: :all))
      assert(link.has_css?(".modcreator-sr", text: "Message on Matrix", visible: :all))
      assert_css(".modcreator-contact", count: 1, visible: :all)
      assert_no_css(".modcreator-handle", visible: :all)
    end

    should "be the creator's name alone while the contact is off, with no Matrix ID anywhere" do
      render_gallery

      box = page.find(".modcreator-name h1.modcreator-title + span.modcreator-contact")
      assert_equal("Maple Woods", box.text)
      assert_equal(false, box.has_css?("svg, a", visible: :all))
      assert_no_css("a.modcreator-contact, [title='Message on Matrix']", visible: :all)
      assert_no_match(/@maple:41chan\.net|matrix\.to|Message on Matrix/, page.native.to_html)
    end

    should "name the creator by their booru account when Matrix gives no name, the ID's own localpart in any case, or a name holding the ID" do
      [nil, "maple", "Maple", "@MAPLE", "@maple:41chan.net", "Maple (@maple:41chan.net)", "Maple (@Maple:41chan.net)"].each do |name|
        with_request_url "/creators/maple" do
          render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar.merge(name: name), can_edit: false, scan: nil, draw: draw))
        end
        assert_css(".modcreator-name span.modcreator-contact", exact_text: "maple leaf")
        assert_no_match(/@maple:41chan\.net/, page.native.to_html)
      end
    end

    should "draw no box when the page names no one to call the creator" do
      @gallery.update!(user: nil)
      with_request_url "/creators/maple" do
        render_inline(CreatorGalleryComponent.new(gallery: @gallery, viewer: @maple, avatar: avatar.merge(name: nil), can_edit: false, scan: nil, draw: draw))
      end
      assert_no_css(".modcreator-contact", visible: :all)
      assert_css("h1.modcreator-title", text: "maple")
    end
  end

  # The hero band's panel (operator, 2026-11-01/02): no eyebrow of tags, and
  # About's button at the panel's top right, its region above the panel,
  # open unless the viewer closed it (ModulationSetting creator_about_open).
  context "the hero band's panel" do
    should "carry no eyebrow over the headline" do
      render_gallery
      assert_no_css(".modcreator-eyebrow", visible: :all)
      assert_css(".modcreator-hero > .modcreator-hero-head > h2.modcreator-headline:first-child", visible: :all)
    end

    should "keep only About's button in the band's panel, its region above the panel, open by default" do
      render_gallery

      assert_css("section.modcreator-hero > button.modcreator-about-btn[data-cg-act='about'][aria-controls='modcreator-about'][aria-expanded='true']")
      assert_css("main.modcreator-main > #modcreator-about.modcreator-about:not([hidden]) + section.modcreator-hero")
      assert_no_css(".modcreator-hero #modcreator-about, .modcreator-hero .modcreator-box, .modcreator-head #modcreator-about, .modcreator-actions .modcreator-about-btn", visible: :all)
      assert_css("#modcreator-about [data-cg-box='bio']", text: "Nothing here yet.")
    end

    should "start About closed for a viewer who closed it" do
      render_gallery(about_open: false)

      assert_css("section.modcreator-hero > button.modcreator-about-btn[aria-expanded='false']")
      assert_css("main.modcreator-main > #modcreator-about[hidden]", visible: :all)
    end

    should "draw no About, band or panel on a page closed to the viewer" do
      render_gallery(closed: true)
      assert_no_css("#modcreator-about, .modcreator-about-btn, .modcreator-hero, .modcreator-contact", visible: :all)
    end
  end

  # The About boxes (operator, 2026-11-02): a chip per box to open and close
  # it, a close control on each, a grip to resize it, every one as the viewer
  # left it (ModulationSetting creator_about_boxes), by a kind that is the
  # same on every gallery.
  context "the About boxes" do
    setup do
      @gallery.update!(bio: "Fields and trees.")
      @gallery.creator_gallery_messages.create!(body: "Commissions open")
      CreatorGalleryComponent.any_instance.stubs(:characters).returns(["pine_(maple)"])
    end

    should "list every box on a chip, in order, each open with a close control and a resize grip" do
      render_gallery

      assert_equal(%w[bio characters blog], page.all("#modcreator-about .modcreator-about-chips button[data-cg-act='box']").pluck("data-v"))
      assert_equal(%w[Bio Characters News], page.all("#modcreator-about .modcreator-about-chips button").map(&:text).map(&:strip))
      assert_css(".modcreator-about-chips button[aria-pressed='true']", count: 3)
      assert_css(".modcreator-about-chips button[data-v='blog'][aria-controls='modcreator-box-blog']")
      assert_css(".modcreator-boxes > section.modcreator-box:not([hidden])", count: 3)
      assert_equal(%w[bio characters blog], page.all(".modcreator-boxes > section.modcreator-box").pluck("data-cg-box"))
      %w[bio characters blog].each do |kind|
        assert_css("section#modcreator-box-#{kind}[data-cg-box='#{kind}'][data-flip-id='#{kind}']:not([style]) .modcreator-box-head button[data-cg-act='box'][data-v='#{kind}'][aria-label^='Close']")
        assert_css("section#modcreator-box-#{kind} > .modcreator-box-body:not([style])")
        assert_css("section#modcreator-box-#{kind} > .modcreator-box-grip[role='separator'][aria-orientation='horizontal'][tabindex='0'][aria-valuemin='80'][aria-valuemax='2000']")
      end
      assert_css("#modcreator-box-characters", text: "pine (maple)")
      assert_css("#modcreator-box-blog", text: "Commissions open")
    end

    # Inside the region named About, nothing else is: the bio's box, its
    # chip and its controls are the Bio, so "Close About" only ever means
    # the region's own button.
    should "name the bio's box Bio, so no control inside About is named About" do
      render_gallery

      assert_css("section#modcreator-box-bio[aria-label='Bio'] .modcreator-box-title", text: "Bio")
      assert_css("#modcreator-box-bio .modcreator-box-x[aria-label='Close Bio']")
      assert_css("#modcreator-box-bio .modcreator-box-grip[aria-label='Resize Bio']")
      assert_no_css("#modcreator-about [aria-label*='About']:not(#modcreator-about):not(.modcreator-about-chips)", visible: :all)
    end

    should "draw each box as the viewer left it: closed ones hidden, a set height kept" do
      render_gallery(about_boxes: { "characters" => { "open" => false }, "blog" => { "open" => true, "h" => 320 }, "gone" => { "open" => false }})

      assert_css(".modcreator-about-chips button[data-v='characters'][aria-pressed='false']")
      assert_css(".modcreator-about-chips button[data-v='blog'][aria-pressed='true']")
      assert_css("#modcreator-box-characters[hidden]", visible: :all)
      # A height is the body's, its content's room: the box's head and grip
      # are always drawn whole around it, so the least height still shows 80px.
      assert_css("#modcreator-box-blog:not([hidden]):not([style]) > .modcreator-box-body[style='height: 320px']")
      assert_css("#modcreator-box-blog .modcreator-box-grip[aria-valuenow='320']")
      assert_css("#modcreator-box-bio:not([hidden]):not([style]) > .modcreator-box-body:not([style])")
      assert_no_css("[data-cg-box='gone'], [data-v='gone']", visible: :all)
    end

    should "name the edit page's sections by a slug of their title, and draw them as boxes like the rest" do
      panels = ["Who sees the posts", "Booru account and creator tags", "Character claims", "Blog messages"].index_with { |name| ApplicationController.helpers.tag.p(name) }
      render_gallery(can_edit: true, editing: true, palette: [], panels: panels, about_boxes: { "character-claims" => { "open" => false }})

      assert_equal(%w[bio characters blog who-sees-the-posts booru-account-and-creator-tags character-claims blog-messages],
                   page.all(".modcreator-about-chips button[data-cg-act='box']").pluck("data-v"))
      assert_css("section#modcreator-box-character-claims.modcreator-box--wide[hidden]", visible: :all)
      assert_css("section#modcreator-box-who-sees-the-posts.modcreator-box--wide:not([hidden]) > .modcreator-box-body", text: "Who sees the posts")
    end

    should "leave no trace of the old hide-and-list mechanism" do
      render_gallery
      assert_no_css(".modcreator-about-hidden, [data-cg-region='hidden-panels'], [data-cg-act='hide-panel'], [data-cg-act='show-panel'], [data-cg-panel]", visible: :all)
    end
  end
  # The wheel toggle (operator, 2026-11-01): on every hero band, the page's
  # wheel unless the viewer turns it on (ModulationSetting wheel_scroll).
  context "the hero band's wheel toggle" do
    should "leave the wheel to the page by default" do
      render_gallery

      assert_css(".modland:not(.is-wheel) .modland-stage-wrap > button.modland-wheel-toggle[data-act='wheel'][role='switch'][aria-checked='false']", visible: :all)
      assert_css(".modland-arrow--prev[aria-label='Previous']", visible: :all)
      assert_css(".modland-arrow--next[aria-label='Next']", visible: :all)
    end

    should "draw the band in wheel mode for a viewer who turned it on, on the page and in its editor" do
      [{}, { can_edit: true, editing: true, palette: [], panels: {}}].each do |options|
        render_gallery(wheel: true, **options)

        assert_css(".modland.is-wheel button.modland-wheel-toggle[aria-checked='true']", visible: :all)
        assert_css(".modland.is-wheel .modland-arrow--prev[aria-label='Up: previous']", visible: :all)
        assert_css(".modland.is-wheel .modland-arrow--next[aria-label='Down: next']", visible: :all)
        assert_css(".modland-arrow", count: 2, visible: :all)
      end
    end
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

    should "mark A's stations with the site's bundled logo, or its letter where the site has none" do
      render_gallery(draw: draw(tuner: { "enabled" => true, "placement" => "A" }, harmonics: [@card.merge(logo: "bluesky-logo.png"), @card.merge(id: 12, number: 2)]))

      logo, letter = page.all(".cg-tuner--a .cg-tuner-station b", visible: :all).to_a
      assert_match(/bluesky-logo/, logo.find("img", visible: :all)["src"])
      assert_equal("B", letter.text(:all).strip)
      assert_equal(false, letter.has_css?("img", visible: :all))
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
      @gallery.creator_gallery_post_views.create!(post_id: @stored[2].id, flip_h: true, flip_v: false, x: 0, y: -50, scale: 900, stretch: 1000)
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

    should "start the editor from the saved views, to re-apply each when its post is chosen" do
      data = JSON.parse(page.find("[data-editor]")["data-editor"])

      assert_equal([{ "post_id" => @stored[2].id, "flip_h" => true, "flip_v" => false, "x" => 0, "y" => -50, "scale" => 900, "stretch" => 1000 }],
                   data["draft"]["views"])
    end

    should "draw the editor's bar and the page's own sections as panels" do
      assert_css(".modcreator.is-editing")
      assert_css("[data-cg-act='save'][disabled]")
      assert_css("[data-cg-sheet='page']", visible: :all)
      assert_css("[data-cg-sheet='layout'] [data-cg-act='layout']", count: CreatorGalleryLayout::LAYOUTS.size, visible: :all)
      assert_css("section.modcreator-box--wide[data-cg-box='blog-messages'] #blog-form", visible: :all)
      # Discard reloads the page; a field the browser refilled would show what was discarded.
      assert_no_css("[data-cg-field]:not([autocomplete='off'])", visible: :all)
      assert_no_link("Edit Gallery")
    end

    should "draw the contact link hidden and the name box shown while the contact is off, to preview the switch" do
      assert_css(".modcreator-name a.modcreator-contact[data-cg-contact][hidden][title='Message on Matrix']", visible: :all)
      assert_css(".modcreator-name span.modcreator-contact[data-cg-contact-off]:not([hidden])", text: "Maple Woods")
      assert_css(".modcreator-main > #modcreator-about:not([hidden]) [data-cg-box='blog-messages']", visible: :all)
      assert_no_css(".modcreator-eyebrow", visible: :all)
    end
  end
end
