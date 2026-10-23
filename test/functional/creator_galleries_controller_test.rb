# frozen_string_literal: true

require "test_helper"

class CreatorGalleriesControllerTest < ActionDispatch::IntegrationTest
  # What CreatorPrefixes says when the live list cannot be read: a path on
  # the server, an errno, the fix's command. For the log, never a page.
  BROKEN = "the creator-prefix list /srv/booru/config/creator_prefixes.yml cannot be read (EACCES). Fix: chmod 644 /srv/booru/config/creator_prefixes.yml " \
           "(the canon copy is fourier-basis ops/hetzner/danbooru/creator_prefixes.yml)"

  def edit_as(user, headers: @maple_header, **params)
    get_auth edit_creator_gallery_path(@gallery), user, headers: headers, params: params
    assert_response :success
  end

  def show_as(user)
    user ? get_auth(creator_gallery_path(@gallery), user) : get(creator_gallery_path(@gallery))
    assert_response :success
  end

  context "The creator galleries controller" do
    setup do
      @gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", title: "Alice")
    end

    should "show a gallery publicly" do
      get creator_gallery_path(@gallery)
      assert_response :success
    end

    # The security-critical gate: writes are locked to the page's Matrix identity.
    should "forbid editing without a fourier identity" do
      get edit_creator_gallery_path(@gallery)
      assert_response 403
    end

    should "allow editing with the matching fourier identity" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      assert_response :success
    end

    should "forbid editing with a different fourier identity" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }
      assert_response 403
    end

    # Stage-4 browser check (2026-10-09): a moderator, or the creator signed
    # in to the booru without the Matrix identity, got the bare "You do not
    # have permission"; the refusal's own sentence, with its remedy, is shown.
    should "tell a refused editor why, and what to do, on the 403 page" do
      [create(:moderator_user), create(:user)].each do |user|
        get_auth edit_creator_gallery_path(@gallery), user

        assert_response 403
        # The shared "Oh No!" error page (operator, 2026-10-10); the refusal is its details line.
        assert_select "h1", "Oh No!"
        assert_select "p", text: /This page can only be edited by its owner, the Matrix account @alice:41chan\.net, or by an admin\./
        # The remedy names WHERE the sign-in button is (browser recheck, 2026-10-09).
        assert_select "p", text: %r{open http://\S+/creators/#{@gallery.slug}, use "Sign in with Matrix" there as @alice:41chan\.net, then use Edit Gallery again}
        assert_select "p", text: /You do not have permission to visit this page/, count: 0
      end
    end

    # A 120-character size made the settings form, and so the edit page,
    # scroll sideways at phone width (stage-4 browser check, 2026-10-09).
    should "not size the title box from its maxlength" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      assert_select "input[data-cg-field='title'][maxlength='120']"
      assert_select "input[data-cg-field='title'][size]", 0

      get new_creator_gallery_path, headers: { "X-Fourier-Identity" => "@bob:41chan.net" }
      assert_response :success
      assert_select "input[name='creator_gallery[title]'][maxlength='120']"
      assert_select "input[name='creator_gallery[title]'][size]", 0
    end
  end

  # THE LAYOUT (Creator Gallery rebuild, 2026-10-23): the editor's candidate
  # list, its save, the API's one-post door, and what a signed-out viewer of
  # a promoted page is granted. Answers are read as JSON and recorded state.
  context "The gallery layout" do
    setup do
      @tunnel = create(:contributor_user)
      @gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", title: "Alice")
      @alice = { "X-Fourier-Identity" => "@alice:41chan.net" }
      @posts = Array.new(6) do |i|
        post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "night neon #{i.even? ? "rain" : "snow"}", rating: "g") }
        FourierPostCreator.create!(post: post, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
        post
      end
      @look = {
        headline: "After Hours", subline: "", banner: { post_id: @posts[0].id, y: 50 }, depth: { blur: 18, dim: 45, parallax: 40 },
        hero: { tags: %w[night], effect: "glide", dir: "left", hold: 5, cells: 5, posts: @posts.map(&:id) },
        layout: "4",
        minis: [{ tag: "rain", effect: "slide", dir: "left", hold: 4, posts: [@posts[0].id] },
                { tag: "snow", effect: "fade", dir: "up", hold: 4, posts: [@posts[1].id] },
                { tag: "neon", effect: "drift", dir: "down", hold: 4, posts: [@posts[2].id] },
                { tag: "night", effect: "flip", dir: "right", hold: 4, posts: [@posts[3].id] }],
      }
    end

    should "answer the editor's candidate list for a band's tags, newest first" do
      get edit_creator_gallery_path(@gallery, format: :json), params: { tags: "night rain" }, headers: @alice

      assert_response :success
      assert_equal([@posts[4], @posts[2], @posts[0]].map(&:id), response.parsed_body["slides"].pluck("id"))
      assert_equal(3, response.parsed_body["total"])
      assert_equal(300, response.parsed_body["cap"])
    end

    should "keep the candidate list behind the owner gate" do
      get edit_creator_gallery_path(@gallery, format: :json), params: { tags: "night" }, headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }
      assert_response 403
    end

    should "save the whole layout and the page fields at once" do
      patch creator_gallery_path(@gallery), params: { creator_gallery: { title: "Alice After Hours", bio: "", matrix_contact: "" }, layout: @look },
                                            headers: @alice, as: :json

      assert_response :success
      assert_equal({ "ok" => true }, response.parsed_body)
      @gallery.reload
      assert_equal("Alice After Hours", @gallery.title)
      assert_equal("4", @gallery.settings["layout"])
      assert_equal(@posts.map(&:id), @gallery.creator_gallery_posts.where(band: "hero").order(:position).pluck(:post_id))
      assert_equal([@posts[3].id], @gallery.creator_gallery_posts.where(band: "mini4").pluck(:post_id))
    end

    should "refuse a layout with problems, naming each, and write nothing" do
      patch creator_gallery_path(@gallery), params: { creator_gallery: { title: "x" * 121 }, layout: @look.merge(hero: @look[:hero].merge(posts: @posts.first(2).map(&:id))) },
                                            headers: @alice, as: :json

      assert_response 422
      assert_equal({ "ok" => false, "problems" => ["The hero band holds 2 of the 5 posts it needs. Open Posts on the band and pick more.",
                                                   "Title is too long (maximum is 120 characters)"] }, response.parsed_body)
      assert_equal({}, @gallery.reload.settings)
      assert_equal("Alice", @gallery.title)
      assert_equal(0, @gallery.creator_gallery_posts.count)
    end

    # The page fields alone, without a layout (an API client): a refusal
    # names its problems, and never renders the editor half-built.
    should "refuse page fields with problems, naming them" do
      patch creator_gallery_path(@gallery), params: { creator_gallery: { title: "x" * 121 }}, headers: @alice
      assert_redirected_to edit_creator_gallery_path(@gallery)
      assert_equal("Title is too long (maximum is 120 characters)", flash[:notice])

      patch creator_gallery_path(@gallery), params: { creator_gallery: { title: "x" * 121 }}, headers: @alice, as: :json
      assert_response 422
      assert_equal({ "ok" => false, "problems" => ["Title is too long (maximum is 120 characters)"] }, response.parsed_body)
      assert_equal("Alice", @gallery.reload.title)
    end

    should "take a post off the one band named, and off every band when none is" do
      %w[hero mini1 mini2].each_with_index { |band, i| @gallery.creator_gallery_posts.create!(band: band, post: @posts[0], position: i) }

      delete creator_gallery_remove_post_path(@gallery, @posts[0].id), params: { band: "mini1", format: :json }, headers: @alice
      assert_response :success
      assert_equal(%w[hero mini2], @gallery.creator_gallery_posts.where(post_id: @posts[0].id).order(:band).pluck(:band))

      delete creator_gallery_remove_post_path(@gallery, @posts[0].id), params: { format: :json }, headers: @alice
      assert_equal(0, @gallery.creator_gallery_posts.count)
    end

    should "refuse a layout save to anyone but the owner or an admin" do
      patch creator_gallery_path(@gallery), params: { layout: @look }, headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }, as: :json

      assert_response 403
      assert_equal({}, @gallery.reload.settings)
    end

    should "add one post to a band through the API door, and refuse one that does not fit or is not eligible" do
      @gallery.update!(settings: { "hero" => { "tags" => %w[night] }, "layout" => "4", "minis" => [{ "tag" => "rain" }] })
      private_post = @posts[2]
      admin = create(:admin_user)
      CreatorPostAudience.set!(private_post, gallery: @gallery, audience: "private", by: admin)

      post creator_gallery_add_post_path(@gallery), params: { post_id: @posts[0].id, band: "mini1", format: :json }, headers: @alice
      assert_response :success
      post creator_gallery_add_post_path(@gallery), params: { post_id: @posts[1].id, band: "mini1", format: :json }, headers: @alice
      assert_response 422
      assert_equal(["Post ##{@posts[1].id} does not carry rain. Take it off miniband 1 or change its tag."], response.parsed_body["problems"])
      # As an admin: the curator's Matrix-only request is answered not found
      # for this post (Post.find_visible!) before eligibility is asked.
      post_auth creator_gallery_add_post_path(@gallery), admin, params: { post_id: private_post.id, format: :json }
      assert_response 422
      assert_equal(["Post ##{private_post.id} cannot be chosen: its audience is private. Make it public on Who sees your posts, or take it off."],
                   response.parsed_body["problems"])

      assert_equal([["mini1", @posts[0].id]], @gallery.creator_gallery_posts.pluck(:band, :post_id))
    end

    # The ruling's second half: a signed-out viewer of a promoted page may
    # open exactly what the page drew for them -- the hero, the minibands and
    # the banner -- while it is fresh: not a chosen post the page no longer
    # draws, not one made private since, and nothing once the grant lapses.
    should "grant a signed-out viewer of a promoted page the posts it drew, and nothing else, while fresh" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      banner = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "dawn", rating: "g") }
      FourierPostCreator.create!(post: banner, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
      @gallery.update!(promoted_at: Time.current, settings: { "hero" => { "tags" => %w[rain] }, "banner" => { "post_id" => banner.id }, "layout" => "1-2", "minis" => [{ "tag" => "snow" }] })
      @posts.each_with_index { |post, i| @gallery.creator_gallery_posts.create!(band: "hero", post: post, position: i) }
      @gallery.creator_gallery_posts.create!(band: "mini1", post: @posts[1], position: 0)
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: create(:admin_user))
      create_list(:post, 21) # rubocop:disable FactoryBot/ExcessiveCreateList -- off the gallery's first page, so only the draw can grant them

      get creator_gallery_path(@gallery)

      assert_response :success
      # Rain on the even posts, snow on the odd; the first is private now.
      drawn = [banner, @posts[1], @posts[2], @posts[4]]
      shown = ->(post) { MembersOnly.anonymous_shown_post?(post.id, safe_mode: false) }
      drawn.each { |post| assert(shown.call(post), "drawn post ##{post.id} was not granted") }
      [@posts[0], @posts[3], @posts[5]].each { |post| assert_not(shown.call(post), "undrawn post ##{post.id} was granted") }
      travel_to(3.hours.from_now) do
        drawn.each { |post| assert_not(shown.call(post), "post ##{post.id} was still granted three hours on") }
      end
    end
  end

  # THE PANEL ON THE EDIT SCREEN, and the visitor's join section on the
  # public page (CREATOR_VISIBILITY sections 4-7, Q3-Q9; 2026-10-09).
  context "The creator panel" do
    setup do
      CreatorPrefixes.reset!
      CreatorTagRelease.reset_cache!
      @maple_header = { "X-Fourier-Identity" => "@maple:41chan.net" }
      @tunnel = create(:builder_user, name: "tunnel")
      @admin = create(:admin_user)
      @maple = create(:user)
      @fan = create(:user)
      @member = create(:user)
      @stranger = create(:user)
      @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @maple)
      @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
      @hand = CreatorGroup.make!(@gallery, name: "41chan_maple_handpicked", by: @maple)
      @tier.add_member!(@member, by: @maple)
    end

    context "on the edit screen" do
      should "show the requests inbox only while a request waits" do
        edit_as(@maple)
        assert_select "#creator-panel-requests", 0
        assert_select "#creator-panel-groups", text: /No one is waiting/

        CreatorJoinRequest.file!(@tier, @fan, note: "please")
        edit_as(@maple)
        assert_select "#creator-panel-requests h3", text: "People asking to join (1)"
        assert_select "#creator-panel-requests td", text: "please"
      end

      should "say what a block does and does not stop, in plain words" do
        edit_as(@maple)
        assert_select "#creator-panel-people", text: /A post open to Everyone can still be looked at by anyone who signs out, this person included\. A block stops the account, not the eyes\./
      end

      should "tell each non-writer what to do instead of showing the panel" do
        {
          -> { @gallery.update!(user_id: nil) } => /once this page is linked to your booru account/,
          -> { @gallery.update!(user_id: create(:user).id) } => /Sign in to the booru as .* to manage who sees your posts/,
          -> { @gallery.update!(user_id: create(:banned_user).id) } => /A banned account cannot change who sees its posts/,
        }.each do |arrange, words|
          arrange.call
          edit_as(@maple)
          assert_select ".modcreator-panel-refusal", text: words
          assert_select "#creator-panel-default", 0
        end
      end

      should "show an admin the whole panel, saying the changes are logged under their name" do
        edit_as(@admin, headers: {})
        assert_select ".modcreator-panel-admin", text: /logged under your name/
        assert_select "#creator-panel-default"
      end

      should "name the release precondition while a held-back creator tag is unreleased, and offer the release once a default is chosen" do
        artist = as(@admin) { create(:artist, name: "aichan_maple") }
        ArtistClaim.create!(artist: artist, creator_gallery: @gallery).approve!(by: @admin)

        edit_as(@maple)
        assert_select "#creator-panel-release", text: /posts tagged aichan_maple follow the aichan_ site rule: only admins and you can see them\. Nothing on this panel shows them to anyone else until the tag is released\./
        assert_select "#creator-panel-release", text: /Choose who sees your posts below first; then you can release aichan_maple/
        assert_select "#creator-panel-release button", 0

        @gallery.set_default_audience!("private", by: @maple)
        edit_as(@maple)
        assert_select "#creator-panel-release form[action='#{update_release_creator_prefixes_path}'] button", text: "Release aichan_maple"

        CreatorTagRelease.set!("aichan_maple", released: true, by: @admin)
        edit_as(@maple)
        assert_select "#creator-panel-release", 0
      end

      # The live list broken: visibility keeps the last good list (it never
      # fails open), so the precondition is still stated.
      should "still state the release precondition while the live prefix list is broken" do
        artist = as(@admin) { create(:artist, name: "aichan_maple") }
        ArtistClaim.create!(artist: artist, creator_gallery: @gallery).approve!(by: @admin)
        CreatorPrefixes.visibility_config
        CreatorPrefixes.stubs(:config).raises(CreatorPrefixes::ConfigError, "the list broke")

        edit_as(@maple)
        assert_select "#creator-panel-release", text: /aichan_maple follow the aichan_ site rule/
      end

      # Fork: in words (BUR review 2026-10-19). What is wrong with the list
      # (a path on the server, an errno, the fix's command) goes to the log,
      # never onto a creator's page.
      should "say so in words when even the release copy of the prefix list cannot be read, and log what is wrong" do
        Rails.logger.stubs(:error)
        Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(BROKEN) }.at_least_once
        CreatorPanelComponent.any_instance.stubs(:held_back).raises(CreatorPrefixes::ConfigError, BROKEN)
        edit_as(@admin, headers: {})
        assert_select "#creator-panel-release", text: /The creator prefix list cannot be read right now; the server log says what is wrong\. This panel will say which of your tags are held back once the site owner fixes it\./
        assert_no_match(%r{/srv|EACCES|chmod|fourier-basis}, response.body)
      end

      should "keep what is wrong with the live prefix list off the creator's own edit page" do
        Rails.logger.stubs(:error)
        Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(BROKEN) }.at_least_once
        CreatorPrefixes.visibility_config
        CreatorPrefixes.stubs(:config).raises(CreatorPrefixes::ConfigError, BROKEN)

        edit_as(@maple)
        assert_match(/Creator tags cannot be claimed right now: the creator-prefix list is broken; the server log says what is wrong\. The site owner fixes the list, then try again/, response.body)
        assert_no_match(%r{/srv|EACCES|chmod|fourier-basis}, response.body)
      end

      should "open one post's editor for a post the creator controls, and refuse others in one sentence" do
        post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "41chan_maple 41chan_alice landscape") }
        CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", user: create(:user))
        edit_as(@maple, post_id: post.id)
        assert_select ".modcreator-panel-editor h4", text: "Post ##{post.id}"
        assert_select ".modcreator-panel-editor", text: /Another creator also controls this post\. Whoever of you is stricter wins for each viewer\./

        other = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
        edit_as(@maple, post_id: other.id)
        assert_select "#creator-panel-posts", text: /Post ##{other.id} is not one of your posts \(or does not exist\)/
        assert_select ".modcreator-panel-editor", 0
      end

      should "count an override on a post the creator no longer controls, never listing it" do
        artist = as(@admin) { create(:artist, name: "4chan_maple") }
        claimed = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "4chan_maple landscape") }
        claim = ArtistClaim.create!(artist: artist, creator_gallery: @gallery).tap { |c| c.approve!(by: @admin) }
        CreatorPostAudience.set!(claimed, gallery: @gallery, audience: "private", by: @maple)
        claim.update!(status: "rejected")

        edit_as(@maple)
        assert_select "#creator-panel-posts", text: /1 older setting is on posts that are no longer yours and has no effect\./
        assert_no_match(/##{claimed.id}\b/, css_select("#creator-panel").text)
      end

      should "count active and ended members apart, and mark a member kept out" do
        lapsed = create(:user)
        @tier.add_member!(lapsed, by: @maple, expires_at: 1.day.from_now)
        CreatorUserRule.set!(@gallery, @member, rule: "block", by: @maple)
        travel(2.days) do
          edit_as(@maple)
          assert_select ".modcreator-panel-group summary", text: /41chan_maple_tier_1 \(and every higher tier\) - 1 member \(1 ended\)/
          assert_select ".modcreator-panel-badge", text: "kept out: a block beats membership"
        end
      end
    end

    context "on the public page" do
      should "show nothing about groups to a signed-out visitor, the creator, or an account kept out" do
        blocked = create(:user)
        CreatorUserRule.set!(@gallery, blocked, rule: "block", by: @maple)
        [nil, @maple, blocked].each do |viewer|
          show_as(viewer)
          assert_select "#creator-join", 0
          assert_no_match(/41chan_maple_tier_1|41chan_maple_handpicked/, response.body)
        end
      end

      should "show nothing when no group is open and the viewer is in none" do
        @tier.open_to_requests!(false, by: @maple)
        show_as(@stranger)
        assert_select "#creator-join", 0
      end

      should "name the open group and nothing else to a member of the site" do
        CreatorJoinRequest.file!(@tier, @fan, note: "secret note")
        show_as(@stranger)
        assert_select "#creator-join", text: /41chan_maple_tier_1/
        assert_select "#creator-join button", text: "Ask to join 41chan_maple_tier_1"
        assert_no_match(/41chan_maple_handpicked|secret note|#{@fan.name}|#{@member.name}/, css_select("#creator-join").text)
      end

      should "show the viewer each state of their own" do
        CreatorJoinRequest.file!(@tier, @fan)
        show_as(@fan)
        assert_select "#creator-join", text: /You asked on .*; waiting for Maple\./
        assert_select "#creator-join button", text: "Withdraw"

        CreatorJoinRequest.pending.find_by(user: @fan).reject!(by: @maple, note: "full")
        show_as(@fan)
        assert_select "#creator-join", text: /Refused on .*: full\. You can ask again after /

        show_as(@member)
        assert_select "#creator-join", text: /You are in 41chan_maple_tier_1\./

        lapsed = create(:user)
        @tier.add_member!(lapsed, by: @maple, expires_at: 1.day.from_now)
        travel(2.days) do
          show_as(lapsed)
          assert_select "#creator-join", text: /Your membership ended on/
          assert_select "#creator-join button", text: "Ask to join 41chan_maple_tier_1"
        end
      end

      should "list a member's own membership in a group that is not open" do
        @hand.add_member!(@fan, by: @maple)
        show_as(@fan)
        assert_select "#creator-join li", text: /\A\s*41chan_maple_handpicked:\s+You are in 41chan_maple_handpicked\.\s*\z/
      end

      should "say nobody can answer yet for an unlinked creator, with no form" do
        @gallery.update!(user_id: nil)
        show_as(@stranger)
        assert_select "#creator-join", text: /has not linked a booru account yet/
        assert_select "#creator-join form", 0
      end
    end
  end
end
