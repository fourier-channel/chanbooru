# frozen_string_literal: true

require "test_helper"

# The rows a creator's panel writes (design CREATOR_VISIBILITY section 4,
# ruled 2026-10-07): the creator default (public, groups or private, and
# which groups), a per-post override (inherit, public, groups or private, and
# which groups), and per-user allows and blocks, creator-wide or per post.
# Only the creator and an admin write them, only about posts the creator
# controls and groups the creator owns, and every write is an admin-only
# ModAction. What the rows MEAN is CreatorVisibility's (its own test).
class CreatorAudienceTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  setup do
    CreatorPrefixes.reset!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @alice = create(:user)
    @member = create(:user)
    @gallery = gallery_for(@maple, "@maple:41chan.net")
    @alice_gallery = gallery_for(@alice, "@alice:41chan.net")
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    FourierPostCreator.create!(post: @post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    @alice_tier = CreatorGroup.make!(@alice_gallery, name: "41chan_alice_tier_1", tier: 1, by: @alice)
  end

  context "the creator default" do
    # Unset is not public: Q7 opens a creator's Matrix-posted image only on
    # their own allow, "public" among them, so a creator who never chose must
    # stay distinguishable from one who chose public. Once chosen, a choice.
    should "start unset with no groups, and never return to unset" do
      assert_nil(@gallery.default_audience)
      assert_equal(0, CreatorAudienceGroup.count)

      @gallery.set_default_audience!("public", by: @maple)

      assert_equal("public", @gallery.reload.default_audience)
      assert_raises(ActiveRecord::RecordInvalid) { @gallery.set_default_audience!(nil, by: @maple) }
      assert_equal("public", @gallery.reload.default_audience)
    end

    # Private is the creator alone (section 4): a group listed there would be
    # stored, logged as granted, and do nothing.
    should "refuse groups under a private default, loudly" do
      assert_raises(ArgumentError) { @gallery.set_default_audience!("private", by: @maple, group_ids: [@tier.id]) }
      assert_nil(@gallery.reload.default_audience)
      assert_equal(0, CreatorAudienceGroup.count)
    end

    should "be set with its groups, replacing the old ones, and logged" do
      friends = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
      @gallery.set_default_audience!("groups", by: @maple, group_ids: [@tier.id])
      @gallery.set_default_audience!("groups", by: @maple, group_ids: [friends.id])

      assert_equal("groups", @gallery.reload.default_audience)
      assert_equal([[friends.id, nil]], CreatorAudienceGroup.pluck(:creator_group_id, :post_id))
      assert_equal(2, ModAction.where(category: "creator_audience_update", creator: @maple).count)
    end

    should "refuse an unknown audience and another creator's group" do
      assert_raises(ActiveRecord::RecordInvalid) { @gallery.set_default_audience!("friends", by: @maple) }
      assert_raises(ArgumentError) { @gallery.set_default_audience!("groups", by: @maple, group_ids: [@alice_tier.id]) }
      assert_nil(@gallery.reload.default_audience)
      assert_equal(0, CreatorAudienceGroup.count)
    end

    should "be set by nobody but the creator and an admin" do
      assert_raises(User::PrivilegeError) { @gallery.set_default_audience!("private", by: @alice) }
      assert_raises(User::PrivilegeError) { @gallery.set_default_audience!("private", by: create(:moderator_user)) }
      @gallery.set_default_audience!("private", by: @admin)

      assert_equal("private", @gallery.reload.default_audience)
    end
  end

  context "a per-post override" do
    should "be one row per post and creator, with its own groups, and logged" do
      friends = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "groups", by: @maple, group_ids: [@tier.id])
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "public", by: @maple, group_ids: [friends.id])

      row = CreatorPostAudience.sole

      assert_equal(["public", @gallery, @maple], [row.audience, row.creator_gallery, row.updated_by])
      assert_equal([[friends.id, @post.id]], CreatorAudienceGroup.pluck(:creator_group_id, :post_id))
      assert_equal(2, ModAction.where(category: "creator_audience_update", subject: @post).count)
    end

    should "drop its groups when it says inherit" do
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "groups", by: @maple, group_ids: [@tier.id])
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "inherit", by: @maple)

      assert_equal("inherit", CreatorPostAudience.sole.audience)
      assert_equal(0, CreatorAudienceGroup.count)
    end

    # Inherit lists nothing of its own, and private is the creator alone: a
    # group under either would be stored, logged as granted, and do nothing.
    should "refuse groups under inherit or private, loudly" do
      %w[inherit private].each do |audience|
        assert_raises(ArgumentError, audience) { CreatorPostAudience.set!(@post, gallery: @gallery, audience: audience, by: @maple, group_ids: [@tier.id]) }
      end
      assert_equal(0, CreatorPostAudience.count)
      assert_equal(0, CreatorAudienceGroup.count)
    end

    # Section 9: two controllers, narrowest wins -- so neither can write over
    # the other's setting.
    should "keep each controller's own override and groups on a post two creators control" do
      shared = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "41chan_maple 41chan_alice landscape") }
      CreatorPostAudience.set!(shared, gallery: @gallery, audience: "groups", by: @maple, group_ids: [@tier.id])
      CreatorPostAudience.set!(shared, gallery: @alice_gallery, audience: "public", by: @alice, group_ids: [@alice_tier.id])
      CreatorPostAudience.set!(shared, gallery: @alice_gallery, audience: "inherit", by: @alice)

      assert_equal([[@gallery.id, "groups"], [@alice_gallery.id, "inherit"]], CreatorPostAudience.where(post: shared).order(:id).pluck(:creator_gallery_id, :audience))
      assert_equal([[@tier.id, shared.id]], CreatorAudienceGroup.pluck(:creator_group_id, :post_id))
    end

    should "be refused on a post the creator does not control, and with another creator's group" do
      assert_raises(ActiveRecord::RecordInvalid) { CreatorPostAudience.set!(@post, gallery: @alice_gallery, audience: "private", by: @alice) }
      assert_raises(ArgumentError) { CreatorPostAudience.set!(@post, gallery: @gallery, audience: "groups", by: @maple, group_ids: [@alice_tier.id]) }
      assert_raises(ActiveRecord::RecordInvalid) { CreatorPostAudience.set!(@post, gallery: @gallery, audience: "friends", by: @maple) }
      assert_equal(0, CreatorPostAudience.count)
    end

    should "be set by nobody but the creator and an admin" do
      assert_raises(User::PrivilegeError) { CreatorPostAudience.set!(@post, gallery: @gallery, audience: "private", by: @member) }
      CreatorPostAudience.set!(@post, gallery: @gallery, audience: "private", by: @admin)

      assert_equal(@admin, CreatorPostAudience.sole.updated_by)
    end
  end

  context "a per-user rule" do
    should "be one rule per user and scope, replaced by the next, and logged" do
      CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @maple)
      CreatorUserRule.set!(@gallery, @member, rule: "block", by: @maple)
      CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @maple, post: @post)

      assert_equal([["block", nil], ["allow", @post.id]], CreatorUserRule.order(:id).pluck(:rule, :post_id))
      assert_equal(3, ModAction.where(category: "creator_user_rule_update", creator: @maple).count)
    end

    should "be cleared, and logged" do
      CreatorUserRule.set!(@gallery, @member, rule: "block", by: @maple, post: @post)
      CreatorUserRule.clear!(@gallery, @member, by: @maple, post: @post)

      assert_equal(0, CreatorUserRule.count)
      assert_equal(2, ModAction.where(category: "creator_user_rule_update").count)
    end

    should "be refused on a post the creator does not control, and with an unknown rule" do
      assert_raises(ActiveRecord::RecordInvalid) { CreatorUserRule.set!(@alice_gallery, @member, rule: "block", by: @alice, post: @post) }
      assert_raises(ActiveRecord::RecordInvalid) { CreatorUserRule.set!(@gallery, @member, rule: "mute", by: @maple) }
      assert_equal(0, CreatorUserRule.count)
    end

    should "be set by nobody but the creator and an admin" do
      assert_raises(User::PrivilegeError) { CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @member) }
      assert_raises(User::PrivilegeError) { CreatorUserRule.clear!(@gallery, @member, by: @alice) }
    end
  end

  # Q2: moderators see nothing a creator hid, nor who a creator let in.
  should "log every creator visibility action in a category only admins read" do
    categories = %w[creator_audience_update creator_group_create creator_group_delete creator_group_member_add
                    creator_group_member_remove creator_join_request_approve creator_join_request_reject creator_user_rule_update]

    categories.each { |category| assert_includes(ModAction::ADMIN_ONLY_CATEGORIES, category.to_sym) }

    @tier.add_member!(@member, by: @maple)
    moderator = create(:moderator_user)

    assert(ModAction.visible(@admin).exists?(category: "creator_group_member_add"))
    assert_not(ModAction.visible(moderator).exists?(category: "creator_group_member_add"))
    assert_not(ModActionPolicy.new(moderator, ModAction.where(category: "creator_group_member_add").first).show?)
  end
end
