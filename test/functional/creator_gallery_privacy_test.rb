# frozen_string_literal: true

require "test_helper"

# A creator's page made private, and the "Message on Matrix" switch
# (operator, 2026-10-24). Every creator may have a page, so a page says
# whether it is open: a private one shows a visitor nothing but its banner and
# its avatar -- no name, no handle, no About, no News, no band -- and grants
# them the banner alone. Its creator, an admin and the people the creator lets
# in creator-wide (a creator-wide allow, beaten by a creator-wide block) see
# the whole page. The contact link and the Matrix handle show only once the
# creator turns them on, on every page.
class CreatorGalleryPrivacyTest < ActionDispatch::IntegrationTest
  WORDS = ["Rainy Atelier", "I draw rain.", "Commissions open", "After Hours", "@alice:41chan.net", "alice-work", "Message on Matrix", "More from"].freeze

  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    @tunnel = create(:contributor_user)
    @owner = create(:user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", title: "Rainy Atelier", bio: "I draw rain.", user: @owner,
                                      matrix_contact: "@alice-work:41chan.net")
    @posts = Array.new(6) do |i|
      post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "night #{i.even? ? "rain" : "snow"}", rating: "g") }
      FourierPostCreator.create!(post: post, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
      post
    end
    @banner = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "dawn", rating: "g") }
    FourierPostCreator.create!(post: @banner, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
    @gallery.update!(settings: { "headline" => "After Hours", "hero" => { "tags" => %w[night] }, "banner" => { "post_id" => @banner.id }, "layout" => "1-2",
                                 "minis" => [{ "tag" => "snow" }] })
    @posts.first(5).each_with_index { |post, i| @gallery.creator_gallery_posts.create!(band: "hero", post: post, position: i) }
    @gallery.creator_gallery_posts.create!(band: "mini1", post: @posts[5], position: 0)
    @gallery.creator_gallery_messages.create!(body: "Commissions open")
    create_list(:post, 21) # rubocop:disable FactoryBot/ExcessiveCreateList -- off the gallery's first page, so only the draw can grant them
  end

  def shown?(post) = MembersOnly.anonymous_shown_post?(post.id, safe_mode: false)

  def view(user = nil, headers: {})
    user ? get_auth(creator_gallery_path(@gallery), user, headers: headers) : get(creator_gallery_path(@gallery), headers: headers)
    assert_response :success
  end

  # A viewer blocked creator-wide is drawn no banner either: a block hides
  # every post the creator controls.
  def assert_closed(banner: true)
    assert_select ".modcreator-banner img", banner ? { minimum: 1 } : 0
    assert_select ".modcreator-ground img", banner ? { minimum: 1 } : 0
    # The disc's letter is the page's address, never the creator's name.
    assert_select ".modcreator-avatar-letter", text: "A"
    assert_select ".modcreator-private", text: "This gallery is private."
    WORDS.each { |words| assert_no_match(/#{Regexp.escape(words)}/, response.body, "a private page showed #{words.inspect}") }
    assert_select ".modcreator-name, .modcreator-about, .modcreator-main, [data-modland], .modland-pool, #creator-join", 0
    assert_select "title", text: /\Aalice\b/
  end

  def assert_open
    assert_select "h1.modcreator-title", text: "Rainy Atelier"
    assert_select ".modcreator-hero [data-modland]"
    assert_select ".modcreator-minis-title", text: "More from Rainy Atelier"
    assert_select ".modcreator-blog", text: /Commissions open/
    assert_select ".modcreator-private", 0
  end

  context "a private page" do
    setup { @gallery.update!(page_private: true) }

    should "show a signed-out visitor the banner and the avatar alone, and grant them the banner alone" do
      view
      assert_closed
      assert(shown?(@banner), "the banner was not granted")
      @posts.each { |post| assert_not(shown?(post), "post ##{post.id} on a private page was granted") }
    end

    should "show a member it does not let in the banner and the avatar alone, with no join section" do
      CreatorGroup.make!(@gallery, name: "41chan_alice_tier_1", tier: 1, by: @owner, open_to_requests: true)
      view(create(:user))
      assert_closed
      assert_no_match(/41chan_alice_tier_1/, response.body)
    end

    should "show the whole page to its creator, an admin, its verified Matrix owner and a viewer let in creator-wide" do
      allowed = create(:user)
      CreatorUserRule.set!(@gallery, allowed, rule: CreatorUserRule::ALLOW, by: @owner)
      [@owner, @admin, allowed].each do |user|
        view(user)
        assert_open
      end
      reset!
      view(headers: { "X-Fourier-Identity" => "@alice:41chan.net" })
      assert_open
      reset!
      view(headers: { "X-Fourier-Identity" => "@bob:41chan.net" })
      assert_closed
    end

    should "stay closed to a viewer blocked creator-wide, even with an allow, and to one allowed on a single post" do
      both = create(:user)
      CreatorUserRule.set!(@gallery, both, rule: CreatorUserRule::ALLOW, by: @owner)
      CreatorUserRule.set!(@gallery, both, rule: CreatorUserRule::BLOCK, by: @owner, post: @posts[0])
      one_post = create(:user)
      CreatorUserRule.set!(@gallery, one_post, rule: CreatorUserRule::ALLOW, by: @owner, post: @posts[0])
      blocked = create(:user)
      CreatorUserRule.set!(@gallery, blocked, rule: CreatorUserRule::BLOCK, by: @owner)

      view(one_post)
      assert_closed
      view(blocked)
      assert_closed(banner: false)
      # A block on one post leaves a creator-wide allow standing.
      view(both)
      assert_open
    end

    should "take no join request from a viewer it does not let in" do
      group = CreatorGroup.make!(@gallery, name: "41chan_alice_tier_1", tier: 1, by: @owner, open_to_requests: true)
      stranger = create(:user)
      login_as(stranger)
      patch creator_gallery_path(@gallery), params: { join_group: group.id }

      assert_redirected_to creator_gallery_path(@gallery, anchor: "creator-join")
      assert_equal(CreatorGalleriesController::NOT_TAKING_REQUESTS, flash[:notice])
      assert_equal(0, CreatorJoinRequest.count)
    end

    should "be listed by its address alone to a viewer it does not let in" do
      get_auth creator_galleries_path, create(:user)
      assert_response :success
      assert_select ".modcreator-index-list a[href='#{creator_gallery_path(@gallery)}']", text: "alice"
      assert_no_match(/Rainy Atelier|@alice:41chan\.net/, response.body)

      get_auth creator_galleries_path, @owner
      assert_response :success
      assert_select ".modcreator-index-list a", text: "Rainy Atelier"
    end

    should "name no Matrix account in the refusal of its editor" do
      member = create(:user)
      get_auth edit_creator_gallery_path(@gallery), member
      assert_response 403
      assert_no_match(/alice:41chan/, response.body)

      put_auth creator_gallery_path(@gallery, format: :json), member, params: { creator_gallery: { title: "x" }}
      assert_response 403
      assert_no_match(/alice:41chan/, response.parsed_body["message"])
    end

    should "send a viewer it does not let in to an admin, not to the page, even with the contact on" do
      @gallery.update!(show_contact: true)
      CharacterClaim.prepare(@gallery, @owner, "maple").first.file!
      wiki = as(@owner) { create(:wiki_page, title: "maple_(alice)", body: "mine") }
      member = create(:user)

      assert_equal({ "maple_(alice)" => { name: "@alice", href: "/creators/alice", contact: false }}, CharacterClaim.owners(["maple_(alice)"], member))
      get_auth wiki_page_path(wiki), member
      assert_select "#wiki-page-original-character", text: /To suggest a change, ask an admin\./
      put_auth wiki_page_path(wiki), member, params: { wiki_page: { body: "edited" }}
      assert_response 403
      assert_select ".oh-no-reason", text: /To suggest a change, ask an admin\./

      assert_equal({ "maple_(alice)" => { name: "Rainy Atelier", href: "/creators/alice", contact: true }}, CharacterClaim.owners(["maple_(alice)"], @owner))
    end

    should "never be promoted on the front page" do
      @gallery.update!(promoted_at: Time.zone.now)
      assert_not_includes(CreatorGallery.landing_promoted, @gallery)
      @gallery.update!(page_private: false)
      assert_includes(CreatorGallery.landing_promoted, @gallery)
    end

    should "name its characters by the address to a viewer it does not let in" do
      CharacterClaim.prepare(@gallery, @owner, "maple").first.file!
      member = create(:user)
      assert_equal({ "maple_(alice)" => { name: "@alice", href: "/creators/alice", contact: false }}, CharacterClaim.owners(["maple_(alice)"], member))
      assert_equal({ "maple_(alice)" => { name: "Rainy Atelier", href: "/creators/alice", contact: false }}, CharacterClaim.owners(["maple_(alice)"], @owner))
    end
  end

  context "the Matrix contact" do
    should "be off until the creator turns it on, for every page" do
      view
      assert_select ".modcreator-actions a[href^='https://matrix.to/']", 0
      assert_select ".modcreator-handle", 0
      assert_no_match(/alice-work/, response.body)
      assert_open

      get_auth creator_galleries_path, create(:user)
      assert_response :success
      assert_select ".modcreator-index-list a", text: "Rainy Atelier"
      assert_select ".modcreator-index-handle", 0
    end

    should "show the link and the handle once on" do
      @gallery.update!(show_contact: true)
      view
      assert_select ".modcreator-actions a[href='https://matrix.to/#/@alice-work:41chan.net']", text: /Message on Matrix/
      assert_select ".modcreator-handle", text: "@alice:41chan.net"

      get_auth creator_galleries_path, create(:user)
      assert_response :success
      assert_select ".modcreator-index-handle", text: "@alice:41chan.net"
    end

    should "say how to reach the creator only where a contact is shown" do
      CharacterClaim.prepare(@gallery, @owner, "maple").first.file!
      wiki = as(@owner) { create(:wiki_page, title: "maple_(alice)", body: "mine") }
      member = create(:user)
      get_auth wiki_page_path(wiki), member
      assert_select "#wiki-page-original-character", text: /To suggest a change, ask an admin\./
      assert_no_match(/message them from their creator page/, response.body)

      @gallery.update!(show_contact: true)
      get_auth wiki_page_path(wiki), member
      assert_select "#wiki-page-original-character", text: /To suggest a change, message them from their creator page\./
    end
  end

  context "the editor" do
    should "save both switches with the page, and start each page with both off" do
      assert_not(@gallery.page_private)
      assert_not(@gallery.show_contact)

      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      assert_response :success
      assert_select "input[type=checkbox][data-cg-field='page_private']:not([checked])"
      assert_select "input[type=checkbox][data-cg-field='show_contact']:not([checked])"

      patch creator_gallery_path(@gallery), params: { creator_gallery: { title: "Rainy Atelier", page_private: true, show_contact: true }},
                                            headers: { "X-Fourier-Identity" => "@alice:41chan.net" }, as: :json
      @gallery.reload
      assert(@gallery.page_private)
      assert(@gallery.show_contact)
    end

    should "refuse a switch set to neither on nor off, as a problem rather than a crash" do
      @gallery.page_private = nil
      assert_not(@gallery.valid?)
      assert_includes(@gallery.errors.full_messages, "Page private must be on or off")
    end
  end
end
