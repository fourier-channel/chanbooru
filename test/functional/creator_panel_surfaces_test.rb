# frozen_string_literal: true

require "test_helper"

# Where the creator panel shows up outside its own page (the creator panel,
# 2026-10-09): the navbar's Requests pill, how a creator hears that someone
# asked to join (they are sent no dmail per request), and the post page's
# read-only "who sees this", for the people who may change it and nobody
# else (Q2: moderators see nothing of a creator's settings).
class CreatorPanelSurfacesTest < ActionDispatch::IntegrationTest
  def sql_during(&)
    statements = []
    counter = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    statements
  end

  def audience_for(user)
    get_auth post_modulation_path(@post), user
    assert_response :success
    response.parsed_body["audience"]
  end

  setup do
    CreatorPrefixes.reset!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @moderator = create(:moderator_user)
    @maple = create(:user)
    @fan = create(:user)
    @member = create(:user)
    @stranger = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @maple)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
    @tier.add_member!(@member, by: @maple)
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    FourierPostCreator.create!(post: @post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
  end

  context "the Requests pill" do
    should "show the linked creator how many wait, linking to the inbox" do
      CreatorJoinRequest.file!(@tier, @fan)
      CreatorJoinRequest.file!(@tier, @stranger)
      get_auth posts_path(preset: "modulation"), @maple

      assert_response :success
      assert_select "#top.modnav a.modnav-pill[href='#{edit_creator_gallery_path(@gallery, anchor: "creator-panel-requests")}']", text: /Requests/
      assert_select "#top.modnav a.modnav-pill", text: /Requests\s*2/
    end

    should "not show while nothing waits, nor to anyone else" do
      get_auth posts_path(preset: "modulation"), @maple
      assert_select "#top.modnav .modnav-pill", text: /Requests/, count: 0

      CreatorJoinRequest.file!(@tier, @fan)
      [@fan, @admin, @moderator].each do |user|
        get_auth posts_path(preset: "modulation"), user
        assert_select "#top.modnav .modnav-pill", { text: /Requests/, count: 0 }, user.name
      end
    end

    should "not ask the database for a signed-out visitor" do
      CreatorJoinRequest.file!(@tier, @fan)
      statements = sql_during { get posts_path(preset: "modulation") }

      assert_response :success
      assert_empty(statements.grep(/creator_join_requests/))
    end
  end

  context "the post page's 'who sees this'" do
    should "be nil for a stranger, a group member and a moderator" do
      [@stranger, @member, @moderator].each do |user|
        assert_nil(audience_for(user), user.name)
      end
    end

    should "tell the creator their default, linking to their panel at this post" do
      audience = audience_for(@maple)

      assert_equal([{ "words" => "Not chosen yet (acts as Everyone) (your default)",
                      "href" => edit_creator_gallery_path(@gallery, post_id: @post.id, anchor: "creator-panel-posts") }], audience)
    end

    should "tell an admin the post's own setting, with its groups" do
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "groups", by: @maple, group_ids: [@tier.id])

      assert_equal("Members of 41chan_maple_tier_1 (and every higher tier) (post setting)", audience_for(@admin).sole["words"])
    end

    # The hottest read path: every payload fetch of every member. Only an
    # admin or a viewer with a page of their own can get an answer, so no
    # one else pays for the question.
    should "not ask who controls the post for a viewer who manages no page" do
      CreatorControl.expects(:controller_gallery_ids).never
      CreatorVisibility.forget!

      [@stranger, @member, @moderator].each do |user|
        assert_nil(ModulationPostComponent.new(post: @post, viewer: user).audience_payload, user.name)
      end
    end

    should "draw it in the More links for the creator, and not for a stranger" do
      get_auth post_path(@post, preset: "modulation"), @maple
      assert_includes(response.body, "who sees this")
      get_auth post_path(@post, preset: "modulation"), @stranger
      assert_not_includes(response.body, "who sees this")
    end
  end
end
