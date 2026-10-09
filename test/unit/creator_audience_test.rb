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

    # No group opens private (Q9): a group listed there would be
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

    # Inherit lists nothing of its own, and no group opens private (Q9): a
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

  # The creator panel (2026-10-09): a refusal of groups is its own class, so
  # the panel rescues it alone; "Members of my groups" with none is refused
  # at the one writer both audiences go through; saving the same choice
  # again writes and logs nothing.
  context "the panel's rules on audiences" do
    should "refuse groups with none, under private or inherit, and another creator's, as a Refusal" do
      [
        -> { @gallery.set_default_audience!("groups", by: @maple, group_ids: []) },
        -> { CreatorPostAudience.set!(@post, gallery: @gallery, audience: "groups", by: @maple) },
        -> { @gallery.set_default_audience!("private", by: @maple, group_ids: [@tier.id]) },
        -> { CreatorPostAudience.set!(@post, gallery: @gallery, audience: "inherit", by: @maple, group_ids: [@tier.id]) },
        -> { @gallery.set_default_audience!("groups", by: @maple, group_ids: [@alice_tier.id]) },
      ].each do |write|
        error = assert_raises(CreatorAudienceGroup::Refusal) { write.call }
        assert_kind_of(ArgumentError, error)
      end
      assert_nil(@gallery.reload.default_audience)
      assert_equal(0, CreatorPostAudience.count)
      assert_equal(0, CreatorAudienceGroup.count)
      assert_equal(0, ModAction.where(category: "creator_audience_update").count)
    end

    should "say how to get what groups-with-none would have meant" do
      error = assert_raises(CreatorAudienceGroup::Refusal) { @gallery.set_default_audience!("groups", by: @maple) }

      assert_equal("Members of my groups needs at least one group ticked. With none, only the people you name could see these posts; choose Private for that.", error.message)
    end

    should "write and log nothing when the same default or override is saved again" do
      assert(@gallery.set_default_audience!("groups", by: @maple, group_ids: [@tier.id]))
      assert_nil(@gallery.set_default_audience!("groups", by: @maple, group_ids: [@tier.id.to_s]))
      assert(CreatorPostAudience.set!(@post, gallery: @gallery, audience: "private", by: @maple))
      assert_nil(CreatorPostAudience.set!(@post, gallery: @gallery, audience: "private", by: @maple))

      assert_equal(2, ModAction.where(category: "creator_audience_update").count)
    end

    should "treat inherit on a post with no override as no change" do
      assert_nil(CreatorPostAudience.set!(@post, gallery: @gallery, audience: "inherit", by: @maple))
      assert_equal(0, CreatorPostAudience.count)
    end
  end

  # A rule that could change nothing is refused (fail loudly, 2026-09-13).
  context "a per-user rule that cannot matter" do
    should "be refused on the creator's own account, an admin and a posting account, and accepted on anyone else" do
      {
        @maple => "You always see your own posts.",
        @admin => "#{@admin.name} is an admin or a posting account and sees every post, so a rule on them changes nothing.",
        @tunnel => "tunnel is an admin or a posting account and sees every post, so a rule on them changes nothing.",
      }.each do |user, words|
        error = assert_raises(ActiveRecord::RecordInvalid) { CreatorUserRule.set!(@gallery, user, rule: "block", by: @maple) }
        assert_equal(words, error.record.errors.full_messages.join)
      end
      assert(CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @maple))
      assert_equal(1, CreatorUserRule.count)
    end

    # The refusal asks exactly what the decision exempts (CreatorVisibility
    # .sees_everything?), on the list visibility reads: while the live
    # prefix list is broken, visibility keeps its last good copy, so a block
    # still takes effect -- and must still save.
    should "still save a block while the live prefix list is broken, and still refuse one on a posting account" do
      CreatorPrefixes.visibility_config
      CreatorPrefixes.stubs(:config).raises(CreatorPrefixes::ConfigError, "the list broke")

      assert(CreatorUserRule.set!(@gallery, @member, rule: "block", by: @maple))
      error = assert_raises(ActiveRecord::RecordInvalid) { CreatorUserRule.set!(@gallery, @tunnel, rule: "block", by: @maple) }
      assert_equal("tunnel is an admin or a posting account and sees every post, so a rule on them changes nothing.", error.record.errors.full_messages.join)
    end

    should "write and log nothing when set the same again or cleared when absent" do
      CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @maple)

      assert_nil(CreatorUserRule.set!(@gallery, @member, rule: "allow", by: @maple))
      assert_equal(false, CreatorUserRule.clear!(@gallery, @alice, by: @maple))
      assert_equal(1, ModAction.where(category: "creator_user_rule_update").count)
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
