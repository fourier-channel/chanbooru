# frozen_string_literal: true

require "test_helper"

# Creator groups, their memberships and join requests (design
# CREATOR_VISIBILITY section 5, Q3 and Q5, ruled 2026-10-07). A group belongs
# to one creator and is named for them (41chan_saber_tier_1); its members are
# booru accounts; a membership says who added it, how, and until when. The
# creator's hand, an approved join request and automation all go through ONE
# write path, CreatorGroup#add_member!, and every creator or admin action is
# an admin-only ModAction.
class CreatorGroupTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  setup do
    CreatorPrefixes.reset!
    @admin = create(:admin_user)
    @maple = create(:user)
    @member = create(:user)
    @stranger = create(:user)
    @gallery = gallery_for(@maple, "@maple:41chan.net")
  end

  context "a group's name" do
    should "be the creator's master tag plus tier_<n> for a tiered group" do
      group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)

      assert_equal(1, group.tier)
      assert_equal(@gallery, group.creator_gallery)
    end

    should "be the creator's master tag plus a suffix for an untiered group, normalised to lowercase" do
      group = CreatorGroup.make!(@gallery, name: " 41chan_Maple_Close_Friends ", by: @maple)

      assert_equal("41chan_maple_close_friends", group.name)
      assert_nil(group.tier)
    end

    should "be refused when it does not follow the house rule" do
      {
        ["41chan_alice_tier_1", 1] => "names another creator",
        ["maple_tier_1", 1] => "lacks the master prefix",
        ["41chan_maple_tier_2", 1] => "names another tier",
        ["41chan_maple_tier_2", nil] => "is named for a tier without one",
        ["41chan_maple_friends", 1] => "has a tier without its name",
        ["41chan_maple_", nil] => "has no suffix",
        ["41chan_maple_bad__name", nil] => "has an empty word",
        ["41chan_maple_tier_0", 0] => "has tier zero",
      }.each do |(name, tier), why|
        group = CreatorGroup.new(creator_gallery: @gallery, name: name, tier: tier)

        assert_not(group.valid?, "#{name.inspect} (tier #{tier.inspect}) #{why}, and was accepted")
      end
    end

    # The master tag names @<localpart> on THIS homeserver only, as
    # CreatorControl reads it: a namesake elsewhere cannot take the name.
    should "be refused to a namesake on another homeserver" do
      namesake = gallery_for(create(:user), "@maple:matrix.org")
      group = CreatorGroup.new(creator_gallery: namesake, name: "41chan_maple_tier_1", tier: 1)

      assert_not(group.valid?)
      assert_match(/no master creator tag/, group.errors.full_messages.join)
    end

    should "be unique" do
      CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)

      assert_raises(ActiveRecord::RecordInvalid) { CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple) }
    end
  end

  context "making and dissolving a group" do
    should "be open to the creator and an admin, and logged" do
      group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      CreatorGroup.make!(@gallery, name: "41chan_maple_tier_2", tier: 2, by: @admin)

      assert_equal(2, ModAction.where(category: "creator_group_create").count)
      assert_equal(@maple, ModAction.where(category: "creator_group_create").first.creator)

      group.add_member!(@member, by: @maple)
      group.dissolve!(by: @maple)

      assert_not(CreatorGroup.exists?(group.id))
      assert_not(CreatorGroupMembership.exists?(creator_group_id: group.id))
      assert(ModAction.exists?(category: "creator_group_delete", creator: @maple))
    end

    should "be refused to anyone else, a moderator included, and to a banned creator" do
      [@stranger, create(:moderator_user), User.anonymous].each do |by|
        assert_raises(User::PrivilegeError, by.name) { CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: by) }
      end
      @maple.update!(is_banned: true)

      assert_raises(User::PrivilegeError) { CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple) }
      assert_equal(0, CreatorGroup.count)
    end
  end

  context "a membership" do
    setup do
      @group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    end

    should "record who added it, how and until when, and be logged" do
      until_then = 30.days.from_now.change(usec: 0)
      membership = @group.add_member!(@member, by: @maple, expires_at: until_then)

      assert_equal([@member, @maple, "creator", until_then], [membership.user, membership.added_by, membership.source, membership.expires_at])
      # Logged against the creator's page, which has a route and outlives a
      # dissolved group; the group is named in the description.
      assert(ModAction.exists?(category: "creator_group_member_add", creator: @maple, subject: @gallery))
    end

    should "be one row per user: adding again renews it" do
      @group.add_member!(@member, by: @maple, expires_at: 1.day.from_now)
      @group.add_member!(@member, by: @admin)

      membership = CreatorGroupMembership.sole

      assert_nil(membership.expires_at)
      assert_equal(@admin, membership.added_by)
    end

    should "count as active only until it expires" do
      @group.add_member!(@member, by: @maple, expires_at: 1.day.from_now)
      @group.add_member!(@stranger, by: @maple)

      assert_equal([@member.id, @stranger.id].sort, CreatorGroupMembership.active.pluck(:user_id).sort)
      travel(2.days) { assert_equal([@stranger.id], CreatorGroupMembership.active.pluck(:user_id)) }
    end

    should "be removable by the creator, and logged" do
      @group.add_member!(@member, by: @maple)
      @group.remove_member!(@member, by: @maple)

      assert_equal(0, CreatorGroupMembership.count)
      assert(ModAction.exists?(category: "creator_group_member_remove", creator: @maple))
    end

    should "be refused to anyone but the creator and an admin" do
      assert_raises(User::PrivilegeError) { @group.add_member!(@member, by: @stranger) }
      assert_raises(User::PrivilegeError) { @group.add_member!(@member, by: create(:moderator_user)) }
      @group.add_member!(@member, by: @maple)

      assert_raises(User::PrivilegeError) { @group.remove_member!(@member, by: @stranger) }
    end

    # Section 5: automation drives the SAME methods, as the system account,
    # and says so in the row.
    should "be open to automation as the system account, marked as automation and nothing else" do
      membership = @group.add_member!(@member, by: User.system, source: "automation", expires_at: 30.days.from_now)

      assert_equal("automation", membership.source)
      assert_raises(User::PrivilegeError) { @group.add_member!(@stranger, by: User.system) }
      @group.remove_member!(@member, by: User.system, source: "automation")

      assert_equal(0, CreatorGroupMembership.count)
    end

    should "refuse an unknown source" do
      assert_raises(ActiveRecord::RecordInvalid) { @group.add_member!(@member, by: @maple, source: "payment") }
    end
  end

  # Q5: a user requests to join, the creator approves or refuses.
  context "a join request" do
    setup do
      @group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      @request = CreatorJoinRequest.create!(creator_group: @group, user: @member, note: "hi")
    end

    should "be one open request per user and group" do
      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.create!(creator_group: @group, user: @member) }
    end

    should "be refused from a current member or a banned account" do
      @group.add_member!(@stranger, by: @maple)

      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.create!(creator_group: @group, user: @stranger) }
      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.create!(creator_group: @group, user: create(:banned_user)) }
    end

    should "be approved through the creator's own add, once, and logged" do
      @request.approve!(by: @maple)

      membership = CreatorGroupMembership.sole

      assert_equal([@member, @maple, "request"], [membership.user, membership.added_by, membership.source])
      assert_equal(["approved", @maple], [@request.reload.status, @request.decided_by])
      assert(ModAction.exists?(category: "creator_join_request_approve", creator: @maple))
      assert_raises(ActiveRecord::RecordInvalid) { @request.approve!(by: @maple) }
    end

    # One path: approval does not write a membership of its own.
    should "approve by calling add_member!" do
      @group.class.any_instance.expects(:add_member!).with(@member, by: @maple, source: "request").once

      @request.approve!(by: @maple)
    end

    # Section 5: an expiry ends access by itself. Approving a request filed
    # before the user joined some other way must not lift it.
    should "leave an existing membership as it is when approved" do
      until_then = 30.days.from_now.change(usec: 0)
      @group.add_member!(@member, by: User.system, source: "automation", expires_at: until_then)
      @request.approve!(by: @maple)

      membership = CreatorGroupMembership.sole

      assert_equal(["automation", until_then], [membership.source, membership.expires_at])
      assert_equal("approved", @request.reload.status)
      assert_match(/already a member/, ModAction.where(category: "creator_join_request_approve").sole.description)
    end

    should "be refused with a note, and logged" do
      @request.reject!(by: @admin, note: "not yet")

      assert_equal(["rejected", "not yet", @admin], [@request.status, @request.note, @request.decided_by])
      assert_equal(0, CreatorGroupMembership.count)
      assert(ModAction.exists?(category: "creator_join_request_reject", creator: @admin))
    end

    should "be decided by nobody but the creator and an admin" do
      assert_raises(User::PrivilegeError) { @request.approve!(by: @stranger) }
      assert_raises(User::PrivilegeError) { @request.reject!(by: @member) }
      assert(@request.reload.pending?)
    end

    should "allow asking again after a refusal" do
      @request.reject!(by: @maple)

      assert(CreatorJoinRequest.create!(creator_group: @group, user: @member).pending?)
    end
  end
end
