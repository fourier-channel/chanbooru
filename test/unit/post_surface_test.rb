# frozen_string_literal: true

require "test_helper"

# PostSurface decides what one post's page offers a viewer (interfaces stage
# 1, step 4c); the Modulation post view draws its payload, the JSON door
# (ModulationController#show) hands the client the same, and posts/show takes
# the edit form's permission from it. What each viewer is offered is pinned
# by the parity and privacy recordings; this pins the shape that makes them
# hold for every interface: the surface decides for the viewer it is handed,
# never for CurrentUser, and each part it cannot decide fails closed and logs.
class PostSurfaceTest < ActiveSupport::TestCase
  include TagQuarantineTestHelper

  def surface_for(post, viewer, query: nil)
    PostSurface.new(post: post, viewer: viewer, query: query)
  end

  # Runs the block with DanbooruLogger keeping what it is handed, and asserts
  # the injected error reached it.
  def assert_logs(message, where)
    logged = []
    DanbooruLogger.stubs(:log).with { |error, *| logged << error.message }
    result = yield
    assert_includes(logged, message, "#{where} raised and said nothing; fix: #{where} logs it (DanbooruLogger.log)")
    result
  end

  context "PostSurface" do
    setup do
      @member = create(:user)
      @post = as(@member) { create(:post, tag_string: "psurface") }
      @other = as(@member) { create(:post, tag_string: "psurface") }
    end

    should "decide for the viewer it is handed, never for CurrentUser" do
      signed_out = CurrentUser.scoped(@member) { surface_for(@post, User.anonymous) }
      member = CurrentUser.scoped(User.anonymous) { surface_for(@post, @member) }

      assert_equal(false, CurrentUser.scoped(@member) { signed_out.can_edit? }, "the signed-out edit permission was decided for CurrentUser (a member); fix: PostSurface asks its `viewer`, never CurrentUser")
      assert_equal(false, CurrentUser.scoped(@member) { signed_out.payload[:can_edit] }, "the signed-out payload's can_edit was decided for CurrentUser; fix: PostSurface asks its `viewer`")
      assert_equal(true, CurrentUser.scoped(User.anonymous) { member.can_edit? }, "the member's edit permission was decided for CurrentUser (signed out); fix: PostSurface asks its `viewer`, never CurrentUser")
      assert_equal(true, CurrentUser.scoped(User.anonymous) { member.payload[:can_edit] }, "the member's payload can_edit was decided for CurrentUser; fix: PostSurface asks its `viewer`")
    end

    # The surface's own guard behind earlier ones: a name hidden from the
    # viewer is already dropped by FourierTagSource for most viewers, so the
    # recordings may never hand the surface one. This hands it one directly.
    should "withhold a banished name handed to it from the tag buckets, the lamps and the categories" do
      banish_tags!("ps_banished")
      surface = surface_for(@post, @member)
      FourierTagSource.stubs(:buckets_and_lamps_for).returns([{ auto: %w[psurface ps_banished] }, { spectrum: %w[psurface ps_banished] }])

      assert_equal({ auto: ["psurface"] }, surface.buckets, "a banished name reached the tag buckets; fix: PostSurface#tag_view filters through TagBanishment")
      assert_equal({ spectrum: ["psurface"] }, surface.lamps, "a banished name reached the lamps; fix: PostSurface#tag_view filters through TagBanishment")
      assert_not_includes(surface.category_tags.values.flatten, "ps_banished", "a banished name reached the category pills; fix: PostSurface#category_tags reads the filtered buckets")
    end

    should "draw a picture it cannot decide as a link with no src, and log it" do
      @post.stubs(:visible?).raises(ActiveRecord::ConnectionNotEstablished, "injected media")

      media = assert_logs("injected media", "PostSurface#media_payload") { surface_for(@post, @member).send(:media_payload) }
      assert_nil(media[:src], "a picture that raised was offered; fix: PostSurface#media_payload fails closed")
      assert_equal("other", media[:kind], "a picture that raised was not drawn as a link; fix: PostSurface#media_payload fails closed")
    end

    should "offer no neighbours in a mode it cannot run, say so, and log it" do
      PostNeighbors.any_instance.stubs(:run).raises(ActiveRecord::ConnectionNotEstablished, "injected mode")

      presets = assert_logs("injected mode", "PostSurface#build_nav_presets") { surface_for(@post, @member, query: "psurface").nav_presets }.reject { it[:key] == "random" }
      assert_not_empty(presets, "fixture: the member is offered keyset modes")
      presets.each do |preset|
        assert_equal(true, preset[:unavailable], "#{preset[:key]} raised and was not marked unavailable; fix: PostSurface#build_nav_presets fails closed per mode")
        assert_empty(preset[:prev_candidates] + preset[:next_candidates], "#{preset[:key]} raised and still offered neighbours; fix: PostSurface#build_nav_presets fails closed per mode")
      end
    end

    should "offer no random neighbours when the trail cannot be read, say so, and log it" do
      RandomTrail.stubs(:for).raises(ActiveRecord::ConnectionNotEstablished, "injected trail")

      random = assert_logs("injected trail", "PostSurface#random_neighbours") { surface_for(@post, @member, query: "psurface").nav_presets }.find { it[:key] == "random" }
      assert_equal(true, random[:unavailable], "random raised and was not marked unavailable; fix: PostSurface#random_neighbours fails closed")
      assert_empty(random[:prev_candidates] + random[:next_candidates], "random raised and still offered neighbours; fix: PostSurface#random_neighbours fails closed")
    end

    should "drop a neighbour it cannot decide, and log it" do
      @other.stubs(:visible?).raises(ActiveRecord::ConnectionNotEstablished, "injected flank")

      shown = assert_logs("injected flank", "PostSurface#flank_shown?") { surface_for(@post, @member).send(:flank_shown?, @other) }
      assert_equal(false, shown, "a neighbour that raised was offered; fix: PostSurface#flank_shown? fails closed")
    end
  end
end
