# frozen_string_literal: true

require "test_helper"

# THE CREATOR'S PANEL'S WRITES (design CREATOR_VISIBILITY sections 4-7, Q3-Q9;
# built 2026-10-09): PATCH creators/:slug with panel=<act>, and a visitor's
# join_group / join_withdraw on the same route (no new routes, 2026-09-24).
#
# Asked here: who may write, both ways, for every act (the verified owner
# signed in as the page's linked account, or an admin; never a moderator,
# Q2); that a join PATCH, the one write exempt from the owner gate, can reach
# nothing else; that every id resolves through this gallery and a refusal
# never tells a missing row from another creator's; that a write is what the
# next request decides by; and that refusals arrive as notices with their
# remedy.
class CreatorPanelTest < ActionDispatch::IntegrationTest
  MAPLE = { "X-Fourier-Identity" => "@maple:41chan.net" }.freeze

  def maple_post(tags = "landscape")
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    post
  end

  def panel(user, act, headers: MAPLE, **params)
    put_auth creator_gallery_path(@gallery), user, params: { panel: act, **params }, headers: headers
  end

  def join(user, **params)
    put_auth creator_gallery_path(@gallery), user, params: params
  end

  # Everything a panel act can change, so "nothing changed" is one comparison.
  def state
    [
      @gallery.reload.attributes.slice("default_audience", "title", "user_id"),
      CreatorGroup.order(:id).pluck(:id, :name, :open_to_requests),
      CreatorGroupMembership.order(:id).pluck(:creator_group_id, :user_id, :source, :expires_at),
      CreatorJoinRequest.order(:id).pluck(:id, :status),
      CreatorUserRule.order(:id).pluck(:user_id, :post_id, :rule),
      CreatorPostAudience.order(:id).pluck(:post_id, :creator_gallery_id, :audience),
      CreatorAudienceGroup.order(:id).pluck(:creator_group_id, :post_id),
      ModAction.count,
    ]
  end

  setup do
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @moderator = create(:moderator_user)
    @maple = create(:user)
    @member = create(:user)
    @fan = create(:user)
    @ruled = create(:user)
    @stranger = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @maple)
    @post = maple_post
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
    @tier.add_member!(@member, by: @maple)
    CreatorUserRule.set!(@gallery, @ruled, rule: "allow", by: @maple)
    @ask = CreatorJoinRequest.file!(@tier, @fan, note: "hello")

    @alice = create(:user)
    @alice_gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", user: @alice)
    @alice_tier = CreatorGroup.make!(@alice_gallery, name: "41chan_alice_tier_1", tier: 1, by: @alice, open_to_requests: true)
    @alice_post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "41chan_alice landscape") }
    @alice_request = CreatorJoinRequest.file!(@alice_tier, @stranger)
  end

  # One representative of every act, as a closure over the setup.
  def acts
    {
      "default_audience" => { audience: "private" },
      "post_audience" => { post_id: @post.id, audience: "private" },
      "make_group" => { suffix: "friends" },
      "group_requests" => { group_id: @tier.id, open_to_requests: "0" },
      "dissolve_group" => { group_id: @tier.id },
      "add_member" => { group_id: @tier.id, user_name: @stranger.name },
      "remove_member" => { group_id: @tier.id, user_id: @member.id },
      "set_rule" => { user_name: @stranger.name, rule: "block" },
      "clear_rule" => { user_id: @ruled.id },
      "approve_request" => { request_id: @ask.id },
      "refuse_request" => { request_id: @ask.id, note: "not now" },
    }
  end

  context "who may write" do
    should "be the verified owner signed in as the linked account, for every act" do
      acts.each_key do |act|
        before = state
        panel(@maple, act, **acts.fetch(act))

        assert_redirected_to(%r{/creators/maple/edit\?*.*#creator-panel-}, act)
        assert_not_equal(before, state, "#{act} changed nothing: #{flash[:notice]}")
        # put each act back where the next one expects it
        teardown_and_setup
      end
    end

    should "be refused to everyone else, for every act, with nothing written" do
      api_key = create(:api_key, user: @maple)
      banned = create(:banned_user)
      acts.each do |act, params|
        before = state
        refusals = {
          "the linked account without the Matrix identity" => -> { panel(@maple, act, headers: {}, **params) },
          "a moderator" => -> { panel(@moderator, act, headers: {}, **params) },
          "a moderator with the owner's identity on a page linked to someone else" => -> { panel(@moderator, act, **params) },
          "a stranger" => -> { panel(@stranger, act, headers: {}, **params) },
          "the owner by API key" => lambda {
            put creator_gallery_path(@gallery, login: @maple.name, api_key: api_key.key), params: { panel: act, **params }, headers: MAPLE
          },
        }
        refusals.each do |who, write|
          write.call

          assert_response(403, "#{act} by #{who}")
          assert_equal(before, state, "#{act} by #{who} wrote something")
        end
        @gallery.update!(user_id: banned.id)
        panel(banned, act, **params)

        assert_response(403, "#{act} by a banned linked owner")
        @gallery.update!(user_id: nil)
        panel(@maple, act, **params)

        assert_response(403, "#{act} by the owner of an unlinked page")
        @gallery.update!(user_id: @maple.id)
        assert_equal(before, state, "#{act} wrote something for a refused writer")
      end
    end

    should "be open to an admin, logged under the admin's name where moderators cannot read it" do
      panel(@admin, "default_audience", headers: {}, audience: "private")

      assert_redirected_to(edit_creator_gallery_path(@gallery, anchor: "creator-panel-default"))
      assert_equal("private", @gallery.reload.default_audience)
      entry = ModAction.where(category: "creator_audience_update").last

      assert_equal(@admin, entry.creator)
      assert_not(ModAction.visible(@moderator).exists?(entry.id))
    end

    should "refuse an unknown act with a 400, writing nothing" do
      before = state
      panel(@maple, "nonsense")

      assert_response(400)
      assert_equal(before, state)
    end

    # The refusal is a sentence with its remedy; the 403 page and the JSON
    # error carry it, not a bare "Access denied" (stage-4 browser check,
    # 2026-10-09).
    should "carry the refusal's own words to the 403 page and the JSON error" do
      @gallery.update!(user_id: nil)
      panel(@maple, "default_audience", audience: "private")

      assert_response(403)
      assert_select "p", text: /Use "Link this page to my booru account" below, signed in to the booru as yourself\./

      put_auth creator_gallery_path(@gallery, format: :json), @moderator, params: { panel: "default_audience", audience: "private" }

      assert_response(403)
      assert_match(/\AThis page can only be edited by its owner, the Matrix account @maple:41chan\.net, or by an admin\./, response.parsed_body["message"])
    end
  end

  # The one write exempt from the owner gate reaches nothing else.
  context "a join request" do
    should "not let a stranger's empty join_group through to the settings" do
      put_auth creator_gallery_path(@gallery), @stranger, params: { join_group: "", creator_gallery: { title: "pwned" }}

      assert_redirected_to(creator_gallery_path(@gallery, anchor: "creator-join"))
      assert_equal("That group is not taking requests. The creator decides which groups people can ask to join.", flash[:notice])
      assert_equal("Maple", @gallery.reload.title)
    end

    should "file the request and nothing else, whatever else rides along" do
      put_auth creator_gallery_path(@gallery), @stranger,
               params: { join_group: @tier.id, creator_gallery: { title: "pwned" }, panel: "dissolve_group", group_id: @tier.id,
                         link_account: 1, claim_tag: "4chan_maple" }

      assert_equal("Maple", @gallery.reload.title)
      assert(CreatorGroup.exists?(@tier.id))
      assert_equal(@maple.id, @gallery.user_id)
      assert(CreatorJoinRequest.pending.exists?(creator_group: @tier, user: @stranger))
    end

    should "tell the creator's own account that it is their group" do
      put_auth creator_gallery_path(@gallery), @maple, params: { join_group: @tier.id }, headers: MAPLE

      assert_equal("This is your own group: you see all your posts already. Add people from your panel.", flash[:notice])
    end

    should "answer a signed-out visitor with the members-only 404" do
      put creator_gallery_path(@gallery), params: { join_group: @tier.id }

      assert_response(404)
      assert_equal(1, CreatorJoinRequest.where(creator_group: @tier).count)
    end

    should "read a closed, a missing and another creator's group alike" do
      closed = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
      notices = [closed.id, 0, @alice_tier.id].map do |id|
        join(@stranger, join_group: id)
        flash[:notice]
      end

      assert_equal(1, notices.uniq.size)
      assert_equal([@alice_request.id], CreatorJoinRequest.where(user: @stranger).pluck(:id))
    end

    should "be withdrawn by the asker only, and only here" do
      join(@stranger, join_withdraw: @alice_request.id)

      assert(CreatorJoinRequest.exists?(@alice_request.id), "another creator's request was withdrawn through this page")
      join(@member, join_withdraw: @ask.id)

      assert(CreatorJoinRequest.exists?(@ask.id), "someone else's request was withdrawn")
      join(@fan, join_withdraw: @ask.id)

      assert_not(CreatorJoinRequest.exists?(@ask.id))
      assert_equal("Your request to join 41chan_maple_tier_1 is withdrawn.", flash[:notice])
    end
  end

  context "every id" do
    should "resolve through this gallery: another creator's group, request or rule reads as missing" do
      before = state
      foreign = {
        "dissolve_group" => [{ group_id: @alice_tier.id }, { group_id: 0 }],
        "add_member" => [{ group_id: @alice_tier.id, user_name: @fan.name }, { group_id: 0, user_name: @fan.name }],
        "approve_request" => [{ request_id: @alice_request.id }, { request_id: 0 }],
        "default_audience" => [{ audience: "groups", group_ids: [@alice_tier.id] }, { audience: "groups", group_ids: [0] }],
      }
      foreign.each do |act, (theirs, missing)|
        panel(@maple, act, **theirs)
        said = flash[:notice]
        panel(@maple, act, **missing)

        assert_equal(flash[:notice], said, "#{act}: another creator's row read differently from a missing one")
      end
      assert_equal(before, state)
    end

    should "refuse a missing post and someone else's post in the identical words" do
      panel(@maple, "post_audience", post_id: 999_999, audience: "private")
      missing = flash[:notice]
      panel(@maple, "post_audience", post_id: @alice_post.id, audience: "private")

      assert_equal(missing.sub("999999", @alice_post.id.to_s), flash[:notice])
      assert_match(/is not one of your posts \(or does not exist\)/, missing)
      assert_equal(0, CreatorPostAudience.count)
    end
  end

  # A write is what the NEXT request decides by.
  context "a round trip" do
    should "hide a post on private and open it again by name" do
      get_auth post_path(@post), @stranger
      assert_response(:success)
      panel(@maple, "default_audience", audience: "private")

      get_auth post_path(@post), @stranger
      assert_response(404)
      panel(@maple, "set_rule", user_name: @stranger.name, rule: "allow")
      get_auth post_path(@post), @stranger

      assert_response(:success)
    end

    should "end a member's access when they are removed" do
      panel(@maple, "default_audience", audience: "groups", group_ids: [@tier.id])
      get_auth post_path(@post), @member

      assert_response(:success)
      panel(@maple, "remove_member", group_id: @tier.id, user_id: @member.id)
      get_auth post_path(@post), @member

      assert_response(404)
    end

    should "set one post differently and send it back to the default" do
      panel(@maple, "post_audience", post_id: @post.id, audience: "private")

      assert_redirected_to(edit_creator_gallery_path(@gallery, post_id: @post.id, anchor: "creator-panel-posts"))
      get_auth post_path(@post), @stranger
      assert_response(404)
      panel(@maple, "post_audience", post_id: @post.id, audience: "inherit")
      get_auth post_path(@post), @stranger

      assert_response(:success)
    end

    should "let a request in, with its end date, and say so" do
      panel(@maple, "approve_request", request_id: @ask.id, until: "2030-12-31")

      assert_equal("#{@fan.name} can now see what 41chan_maple_tier_1 sees, until 2030-12-31.", flash[:notice])
      assert_equal(Time.zone.parse("2030-12-31").end_of_day.to_i, CreatorGroupMembership.find_by(user: @fan).expires_at.to_i)
    end
  end

  context "a refusal" do
    should "arrive as a notice that says what to do" do
      {
        ["add_member", { group_id: @tier.id, user_name: "nobody_here" }] => "No booru account is called \"nobody_here\". Check the spelling; the name field suggests names as you type.",
        ["add_member", { group_id: @tier.id, user_name: @fan.name, until: "2001-01-01" }] => "That date has passed; choose a later one, or leave it empty for no end.",
        ["add_member", { group_id: @tier.id, user_name: @fan.name, until: "31/12/2030" }] => "Write the date as YYYY-MM-DD, or leave it empty for no end.",
        ["add_member", { group_id: @tier.id, user_name: @fan.name, until: "2030-02-30" }] => "Write the date as YYYY-MM-DD, or leave it empty for no end.",
        ["default_audience", { audience: "groups" }] => "Members of my groups needs at least one group ticked. With none, only the people you name could see these posts; choose Private for that.",
        ["set_rule", { user_name: @admin.name, rule: "block" }] => "#{@admin.name} is an admin or a posting account and sees every post, so a rule on them changes nothing.",
        ["default_audience", { audience: "" }] => "Choose Everyone, Members of my groups or Private, then save.",
        ["set_rule", { user_name: @fan.name, rule: "mute" }] => "Choose Let in or Keep out.",
        ["make_group", { suffix: "tier_0" }] => nil,
      }.each do |(act, params), words|
        before = state
        panel(@maple, act, **params)

        assert_response(:redirect, act)
        assert_equal(words, flash[:notice], act) if words
        assert_equal(before, state, "#{act} #{params.inspect} wrote something")
      end
    end

    should "say Nothing changed for a write that changes nothing, and log nothing" do
      panel(@maple, "default_audience", audience: "public")
      before = state
      panel(@maple, "default_audience", audience: "public")

      assert_equal("Nothing changed.", flash[:notice])
      assert_equal(before, state)
    end

    should "say plainly when ticked groups are not kept under private" do
      panel(@maple, "default_audience", audience: "private", group_ids: [@tier.id])

      assert_equal("Who sees your posts: Private. Groups never open a private post, so the ticked groups were not kept.", flash[:notice])
      assert_equal(0, CreatorAudienceGroup.count)
    end

    # Everyone lists groups too (the widening past the level gate), so the
    # reason a post's ticks were dropped is said per audience.
    should "say why a post's ticked groups were not kept, for private and for the default" do
      panel(@maple, "post_audience", post_id: @post.id, audience: "private", group_ids: [@tier.id])

      assert_equal("Post ##{@post.id}: Private. Groups never open a private post, so the ticked groups were not kept.", flash[:notice])
      panel(@maple, "post_audience", post_id: @post.id, audience: "inherit", group_ids: [@tier.id])

      assert_equal("Post ##{@post.id}: back to your default. It now follows your default, which has its own groups; the ticked groups were not kept.",
                   flash[:notice])
    end

    # The refusals come before the no-change comparison (second repair,
    # 2026-10-09): saving a default already on groups-with-none (its only
    # group dissolved, which the panel warns about) is refused with its
    # remedy, not answered "Nothing changed".
    should "refuse Members of my groups with none ticked, though the default already is that" do
      panel(@maple, "default_audience", audience: "groups", group_ids: [@tier.id])
      @tier.dissolve!(by: @maple)
      before = state
      panel(@maple, "default_audience", audience: "groups")

      assert_equal("Members of my groups needs at least one group ticked. With none, only the people you name could see these posts; choose Private for that.",
                   flash[:notice])
      assert_equal(before, state)
    end

    should "say the ticked groups were not kept, though nothing else changed" do
      panel(@maple, "post_audience", post_id: @post.id, audience: "private")
      panel(@maple, "post_audience", post_id: @post.id, audience: "private", group_ids: [@tier.id])

      assert_equal("Nothing changed. Groups never open a private post, so the ticked groups were not kept.", flash[:notice])
      panel(@maple, "default_audience", audience: "private")
      panel(@maple, "default_audience", audience: "private", group_ids: [@tier.id])

      assert_equal("Nothing changed. Groups never open a private post, so the ticked groups were not kept.", flash[:notice])
    end

    should "name tier groups as nesting in the words for an audience" do
      panel(@maple, "default_audience", audience: "groups", group_ids: [@tier.id])

      assert_equal("Who sees your posts: Members of 41chan_maple_tier_1 (and every higher tier).", flash[:notice])
    end
  end

  # A notice says what the write did, and what still stands in the way.
  context "a notice after letting someone in" do
    # approve! keeps a membership the person already holds, with its own end.
    should "say the membership was kept and the date not applied, when the requester was already in" do
      @tier.add_member!(@fan, by: @maple)
      panel(@maple, "approve_request", request_id: @ask.id, until: "2030-12-31")

      assert_equal("#{@fan.name} was already in 41chan_maple_tier_1 (no end); that membership was kept and the date you gave was not applied. " \
                   "Use Renew or Add someone on the group to change its end.", flash[:notice])
      assert_nil(CreatorGroupMembership.find_by(user: @fan).expires_at)
    end

    # Q8: a block beats membership.
    should "say a creator-wide block still keeps them out, after an add and after an approval" do
      CreatorUserRule.set!(@gallery, @fan, rule: "block", by: @maple)
      CreatorUserRule.set!(@gallery, @stranger, rule: "block", by: @maple)
      caveat = "but you keep them out of all your posts, and a block beats membership: remove it under People you let in or keep out to let them see."

      panel(@maple, "approve_request", request_id: @ask.id)
      assert_equal("#{@fan.name} is now in 41chan_maple_tier_1, #{caveat}", flash[:notice])
      panel(@maple, "add_member", group_id: @tier.id, user_name: @stranger.name)

      assert_equal("#{@stranger.name} is now in 41chan_maple_tier_1, #{caveat}", flash[:notice])
    end
  end

  context "making a group" do
    # A group open to requests is named to every signed-in visitor; a group
    # run by hand never is (migration header, 2026-10-09). Fails closed.
    should "make it closed to requests unless the box was ticked, tier or not" do
      panel(@maple, "make_group", suffix: "friends")
      panel(@maple, "make_group", suffix: "tier_2")
      panel(@maple, "make_group", suffix: "tier_3", open_to_requests: "1")

      assert_equal({ "41chan_maple_friends" => false, "41chan_maple_tier_2" => false, "41chan_maple_tier_3" => true },
                   CreatorGroup.where(creator_gallery: @gallery).where.not(id: @tier.id).pluck(:name, :open_to_requests).to_h)
    end
  end

  # The creator's place in the panel is kept for the next page, by URL only.
  context "a write on one group" do
    should "come back with that group open, and its block in view" do
      { "add_member" => { user_name: @stranger.name }, "remove_member" => { user_id: @member.id },
        "group_requests" => { open_to_requests: "0" }}.each do |act, params|
        panel(@maple, act, group_id: @tier.id, **params)

        assert_redirected_to(edit_creator_gallery_path(@gallery, open_group: @tier.id, anchor: "creator-panel-group-#{@tier.id}"), act)
      end
      panel(@maple, "add_member", group_id: @tier.id, user_name: "nobody_here")

      assert_redirected_to(edit_creator_gallery_path(@gallery, open_group: @tier.id, anchor: "creator-panel-group-#{@tier.id}"))
      panel(@maple, "make_group", suffix: "friends")
      made = CreatorGroup.find_by!(name: "41chan_maple_friends")

      assert_redirected_to(edit_creator_gallery_path(@gallery, open_group: made.id, anchor: "creator-panel-group-#{made.id}"))
    end
  end

  # The visitor's own requests stay theirs to see and take back, whatever
  # the creator later does to the group (CREATOR_VISIBILITY Q5).
  context "the visitor's join section" do
    should "still show a waiting request in a group since closed, with its Withdraw" do
      @tier.open_to_requests!(false, by: @maple)
      get_auth creator_gallery_path(@gallery), @fan

      assert_response :success
      assert_select "#creator-join li", text: /41chan_maple_tier_1.*waiting for Maple/m
      assert_select "#creator-join input[name=join_withdraw][value='#{@ask.id}']"
      assert_select "#creator-join input[name=join_group]", count: 0
    end

    should "name no closed group to someone with nothing in it" do
      @tier.open_to_requests!(false, by: @maple)
      get_auth creator_gallery_path(@gallery), @stranger

      assert_response :success
      assert_select "#creator-join", count: 0
    end
  end

  private

  # Undo one act's writes so the next act in a table starts from setup.
  def teardown_and_setup
    [CreatorAudienceGroup, CreatorPostAudience, CreatorUserRule, CreatorJoinRequest, CreatorGroupMembership, CreatorGroup].each(&:delete_all)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
    @tier.add_member!(@member, by: @maple)
    CreatorUserRule.set!(@gallery, @ruled, rule: "allow", by: @maple)
    @ask = CreatorJoinRequest.file!(@tier, @fan, note: "hello")
    @alice_tier = CreatorGroup.make!(@alice_gallery, name: "41chan_alice_tier_1", tier: 1, by: @alice, open_to_requests: true)
    @alice_request = CreatorJoinRequest.file!(@alice_tier, @stranger)
  end
end
