# frozen_string_literal: true

require "test_helper"

class CreatorGalleriesControllerTest < ActionDispatch::IntegrationTest
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
        assert_select "h1", "Access Denied"
        assert_select "p", text: /This page can only be edited by its owner, the Matrix account @alice:41chan\.net, or by an admin\./
        # The remedy names WHERE the sign-in button is (browser recheck, 2026-10-09).
        assert_select "p", text: %r{open http://\S+/creators/#{@gallery.slug}, use "Sign in with Matrix" there as @alice:41chan\.net, then open Edit page again}
        assert_select "p", text: /You do not have permission to visit this page/, count: 0
      end
    end

    # A 120-character size made the settings form, and so the edit page,
    # scroll sideways at phone width (stage-4 browser check, 2026-10-09).
    should "not size the title box from its maxlength" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      assert_select "input[name='creator_gallery[title]'][maxlength='120']"
      assert_select "input[name='creator_gallery[title]'][size]", 0

      get new_creator_gallery_path, headers: { "X-Fourier-Identity" => "@bob:41chan.net" }
      assert_response :success
      assert_select "input[name='creator_gallery[title]'][maxlength='120']"
      assert_select "input[name='creator_gallery[title]'][size]", 0
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

      should "say so when even the release copy of the prefix list cannot be read" do
        CreatorPanelComponent.any_instance.stubs(:held_back).raises(CreatorPrefixes::ConfigError, "the list broke")
        edit_as(@admin, headers: {})
        assert_select "#creator-panel-release", text: /The creator prefix list cannot be read right now \(the list broke\)/
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
