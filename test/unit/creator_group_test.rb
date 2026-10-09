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

    should "be unique, saying it is one of yours when it is" do
      CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)

      error = assert_raises(ActiveRecord::RecordInvalid) { CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple) }
      assert_equal("Name 41chan_maple_tier_1 is already one of your groups; it is listed under Your groups.",
                   error.record.errors.full_messages.join)
    end

    # A name taken by another creator before this one was known (no page, no
    # recorded post) is not theirs to find under Your groups: the refusal
    # says who settles it (second repair, 2026-10-09).
    should "be unique, sending the creator to an admin when another creator's group holds it" do
      sab = gallery_for(create(:user), "@sab:41chan.net")
      CreatorGroup.make!(sab, name: "41chan_sab_er_tier_1", by: sab.user)
      sab_er = gallery_for(create(:user), "@sab_er:41chan.net")

      error = assert_raises(ActiveRecord::RecordInvalid) { CreatorGroup.make!(sab_er, name: "41chan_sab_er_tier_1", tier: 1, by: sab_er.user) }
      assert_equal("Name 41chan_sab_er_tier_1 is held by another creator's group, made before your page or posts were known here. " \
                   "An admin settles whose it is: ask one, or choose another name.", error.record.errors.full_messages.join)
    end

    # Matrix localparts may hold underscores, so @sab's master tag plus a
    # suffix can spell @sab_er's group names. A name that is, or runs on
    # from, another creator's master tag is refused, in words that name
    # nobody -- whether that creator is known by a page or by a post the
    # posting bot recorded as theirs (compared as MXIDs are, ignoring case).
    should "be refused when it is or runs on from another creator's master tag" do
      sab = gallery_for(create(:user), "@sab:41chan.net")
      gallery_for(create(:user), "@sab_er:41chan.net")
      bot = create(:builder_user)
      FourierPostCreator.create!(post: create(:post), mxid: "@Sab_Ex:41chan.net", recorded_by: bot.id)
      %w[41chan_sab_er_tier_1 41chan_sab_er 41chan_sab_er_friends 41chan_sab_ex_tier_2].each do |name|
        group = CreatorGroup.new(creator_gallery: sab, name: name, tier: name[/_tier_(\d+)\z/, 1]&.to_i)

        assert_not(group.valid?, "#{name} was accepted for @sab")
        assert_equal("Name #{name} reads as another creator's name. Choose a name that starts with a word of your own after 41chan_sab_, " \
                     "like 41chan_sab_tier_1 or 41chan_sab_friends.", group.errors.full_messages.join)
      end

      assert(CreatorGroup.new(creator_gallery: sab, name: "41chan_sab_friends").valid?)
      assert(CreatorGroup.new(creator_gallery: sab, name: "41chan_sab_tier_1", tier: 1).valid?)
    end

    # A bare Tag is not a creator: any member can mint one through an artist
    # entry (ArtistPolicy#create?), so counting it let anyone deny a creator
    # their tier names (second repair, 2026-10-09).
    should "not be refused for a tag a member made, with no creator behind it" do
      sab = gallery_for(create(:user), "@sab:41chan.net")
      as(create(:user)) do
        Artist.create!(name: "41chan_sab_tier_1")
        Artist.create!(name: "41chan_sab_er")
      end

      assert(Tag.exists?(name: %w[41chan_sab_tier_1 41chan_sab_er]))
      assert(CreatorGroup.new(creator_gallery: sab, name: "41chan_sab_tier_1", tier: 1).valid?)
      assert(CreatorGroup.new(creator_gallery: sab, name: "41chan_sab_er_friends").valid?)
    end

    should "be the longer-named creator's own, though the shorter name is a prefix of it" do
      gallery_for(create(:user), "@sab:41chan.net")
      sab_er = gallery_for(create(:user), "@sab_er:41chan.net")

      assert(CreatorGroup.new(creator_gallery: sab_er, name: "41chan_sab_er_tier_1", tier: 1).valid?)
    end
  end

  # The squat the global name index still allows (second repair,
  # 2026-10-09): a group made in a creator's name before the booru knew them.
  # When their page is made, it is closed to requests -- so nobody is drawn
  # to ask the wrong creator -- logged for an admin to settle, and cannot be
  # opened again while its name reads as theirs.
  context "a group named for a creator who arrives later" do
    setup do
      @sab = gallery_for(create(:user), "@sab:41chan.net")
      @squat = CreatorGroup.make!(@sab, name: "41chan_sab_er_tier_1", by: @sab.user, open_to_requests: true)
      @own = CreatorGroup.make!(@sab, name: "41chan_sab_tier_1", tier: 1, by: @sab.user, open_to_requests: true)
    end

    should "be closed to requests and reported to admins when their page is made" do
      sab_er = gallery_for(create(:user), "@sab_er:41chan.net")

      assert_not(@squat.reload.open_to_requests)
      assert(@own.reload.open_to_requests, "a group in sab's own name was closed")
      action = ModAction.where(category: "creator_group_update").last
      assert_equal(@sab, action.subject)
      assert_equal(User.system, action.creator)
      assert_equal("closed creator group 41chan_sab_er_tier_1 to requests: its name reads as creator #{sab_er.matrix_id}'s, whose page was just made. " \
                   "An admin settles whose it is (dissolve it from #{@sab.matrix_id}'s panel, or leave it)", action.description)
    end

    should "not touch the longer-named creator's own groups when the shorter one's page is made" do
      kit_ty = gallery_for(create(:user), "@kit_ty:41chan.net")
      theirs = CreatorGroup.make!(kit_ty, name: "41chan_kit_ty_tier_1", tier: 1, by: kit_ty.user, open_to_requests: true)
      gallery_for(create(:user), "@kit:41chan.net")

      assert(theirs.reload.open_to_requests)
      assert_equal(0, ModAction.where(category: "creator_group_update").count)
    end

    should "refuse to be opened again while its name reads as theirs" do
      gallery_for(create(:user), "@sab_er:41chan.net")

      error = assert_raises(ActiveRecord::RecordInvalid) { @squat.reload.open_to_requests!(true, by: @sab.user) }
      assert_equal("41chan_sab_er_tier_1 reads as another creator's name, so it cannot be opened to requests. " \
                   "Make a group named for you instead, like 41chan_sab_tier_1 or 41chan_sab_friends.", error.record.errors.full_messages.join)
      assert_not(@squat.reload.open_to_requests)
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

  # The creator panel (2026-10-09): which groups visitors may ask to join.
  context "opening a group to requests" do
    should "be stored when the group is made" do
      assert(CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true).open_to_requests)
      assert_not(CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple).open_to_requests)
    end

    should "be changed by the creator and an admin, logged where moderators cannot read it" do
      group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      group.open_to_requests!(true, by: @maple)
      group.open_to_requests!(false, by: @admin)

      assert_not(group.reload.open_to_requests)
      assert_equal([@maple, @admin], ModAction.where(category: "creator_group_update").order(:id).map(&:creator))
      assert_equal(0, ModAction.visible(create(:moderator_user)).where(category: "creator_group_update").count)
    end

    should "log nothing when it already was as asked" do
      group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)

      assert_nil(group.open_to_requests!(false, by: @maple))
      assert_equal(0, ModAction.where(category: "creator_group_update").count)
    end

    should "be refused to a moderator and a stranger" do
      group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      [create(:moderator_user), @stranger].each do |by|
        assert_raises(User::PrivilegeError) { group.open_to_requests!(true, by: by) }
      end
      assert_not(group.reload.open_to_requests)
    end
  end

  # Section 5: automation drives the SAME methods and never undoes the
  # creator's hand; the guards live in those methods (creator panel,
  # 2026-10-09).
  context "automation" do
    setup do
      @group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    end

    should "leave a member the creator added as they are, and say so" do
      @group.add_member!(@member, by: @maple)
      kept = @group.add_member!(@member, by: User.system, source: "automation", expires_at: 30.days.from_now)

      assert_equal(["creator", nil], [kept.source, kept.expires_at])
      assert_equal(["creator", nil], CreatorGroupMembership.sole.then { |m| [m.source, m.expires_at] })
      assert_match(/automation left user ##{@member.id} in creator group 41chan_maple_tier_1 unchanged/, ModAction.where(category: "creator_group_member_add").last.description)
    end

    should "leave a member let in by request as they are" do
      @group.add_member!(@member, by: @maple, source: "request")
      @group.add_member!(@member, by: User.system, source: "automation", expires_at: 30.days.from_now)

      assert_equal(["request", nil], CreatorGroupMembership.sole.then { |m| [m.source, m.expires_at] })
    end

    should "renew and remove what automation added" do
      @group.add_member!(@member, by: User.system, source: "automation", expires_at: 10.days.from_now)
      later = 40.days.from_now.change(usec: 0)
      @group.add_member!(@member, by: User.system, source: "automation", expires_at: later)

      assert_equal(later, CreatorGroupMembership.sole.expires_at)
      assert(@group.remove_member!(@member, by: User.system, source: "automation"))
      assert_equal(0, CreatorGroupMembership.count)
    end

    should "be refused removing a member the creator added, who stays" do
      @group.add_member!(@member, by: @maple)

      error = assert_raises(User::PrivilegeError) { @group.remove_member!(@member, by: User.system, source: "automation") }
      assert_match(/by the creator, not by automation\. Only the creator removes them/, error.message)
      assert_equal(1, CreatorGroupMembership.count)
    end

    should "take over a hand-made membership that has already ended" do
      @group.add_member!(@member, by: @maple, expires_at: 1.day.from_now)
      travel(2.days) do
        @group.add_member!(@member, by: User.system, source: "automation", expires_at: 30.days.from_now)

        assert_equal("automation", CreatorGroupMembership.sole.source)
      end
    end
  end

  context "a membership's writes" do
    setup do
      @group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    end

    should "refuse a date that has passed, with its remedy" do
      error = assert_raises(ActiveRecord::RecordInvalid) { @group.add_member!(@member, by: @maple, expires_at: 1.hour.ago) }

      assert_equal("That date has passed; choose a later one, or leave it empty for no end.", error.record.errors.full_messages.join)
      assert_equal(0, CreatorGroupMembership.count)
    end

    should "write and log nothing when adding the same member the same way again" do
      until_then = 30.days.from_now.change(usec: 0)
      @group.add_member!(@member, by: @maple, expires_at: until_then)

      assert_nil(@group.add_member!(@member, by: @maple, expires_at: until_then))
      assert_equal(1, ModAction.where(category: "creator_group_member_add").count)
    end

    # The panel's dates are end_of_day -- nanoseconds, where the column keeps
    # microseconds. The same date again is still no change.
    should "write and log nothing when renewed to the same end of day" do
      @group.add_member!(@member, by: @maple, expires_at: 30.days.from_now.to_date.in_time_zone.end_of_day)

      assert_nil(@group.add_member!(@member, by: @maple, expires_at: 30.days.from_now.to_date.in_time_zone.end_of_day))
      assert_equal(1, ModAction.where(category: "creator_group_member_add").count)
    end

    should "log nothing when removing someone who is not a member" do
      assert_equal(false, @group.remove_member!(@member, by: @maple))
      assert_equal(0, ModAction.where(category: "creator_group_member_remove").count)
    end
  end

  # Q5: a user requests to join, the creator approves or refuses.
  context "a join request" do
    setup do
      @group = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
      @request = CreatorJoinRequest.file!(@group, @member, note: "hi")
    end

    should "be one open request per user and group" do
      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.file!(@group, @member) }
    end

    should "be refused from a current member or a banned account" do
      @group.add_member!(@stranger, by: @maple)

      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.file!(@group, @stranger) }
      assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.file!(@group, create(:banned_user)) }
    end

    should "be approved through the creator's own add, once, and logged" do
      @request.approve!(by: @maple)

      membership = CreatorGroupMembership.sole

      assert_equal([@member, @maple, "request"], [membership.user, membership.added_by, membership.source])
      assert_equal(["approved", @maple], [@request.reload.status, @request.decided_by])
      assert(ModAction.exists?(category: "creator_join_request_approve", creator: @maple))
      error = assert_raises(ActiveRecord::RecordInvalid) { @request.approve!(by: @maple) }
      assert_equal("This request was already approved.", error.record.errors.full_messages.join)
    end

    # A second approval of the same row, from another copy of it (a double
    # click, or the creator and an admin at once), is told and does nothing.
    should "make one membership and one log entry when approved twice at once" do
      other = CreatorJoinRequest.find(@request.id)
      @request.approve!(by: @maple)

      assert_raises(ActiveRecord::RecordInvalid) { other.approve!(by: @admin) }
      assert_equal(1, CreatorGroupMembership.count)
      assert_equal(1, ModAction.where(category: "creator_join_request_approve").count)
    end

    # One path: approval does not write a membership of its own.
    should "approve by calling add_member!" do
      @group.class.any_instance.expects(:add_member!).with(@member, by: @maple, source: "request", expires_at: nil).once

      @request.approve!(by: @maple)
    end

    should "carry an expiry given with the approval into the membership" do
      until_then = 30.days.from_now.end_of_day.change(usec: 0)
      @request.approve!(by: @maple, expires_at: until_then)

      assert_equal(["request", until_then], CreatorGroupMembership.sole.then { |m| [m.source, m.expires_at] })
    end

    # Section 5: an expiry ends access by itself. Approving a request filed
    # before the user joined some other way must not lift it.
    should "leave an existing membership as it is when approved" do
      until_then = 30.days.from_now.change(usec: 0)
      @group.add_member!(@member, by: User.system, source: "automation", expires_at: until_then)
      @request.approve!(by: @maple, expires_at: 90.days.from_now)

      membership = CreatorGroupMembership.sole

      assert_equal(["automation", until_then], [membership.source, membership.expires_at])
      assert_equal("approved", @request.reload.status)
      assert_match(/already a member.*the expiry given was not applied/, ModAction.where(category: "creator_join_request_approve").sole.description)
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

    should "allow asking again once the refusal's cooldown is over, and not before" do
      @request.reject!(by: @maple)

      error = assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.file!(@group, @member) }
      assert_equal("Refused on #{Time.zone.today}. You can ask again after #{Time.zone.today + 7}.", error.record.errors.full_messages.join)
      travel(CreatorJoinRequest::COOLDOWN + 1.minute) { assert(CreatorJoinRequest.file!(@group, @member).pending?) }
    end
  end
end
