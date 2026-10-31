# frozen_string_literal: true

require "test_helper"

# Perks (CREATOR_TUNER.md sec 4.4, operator 2026-10-31): an admin's grant
# raises one account's limit, logged where only admins read it, and is
# honoured only while the account is in good standing.
class UserPerkTest < ActiveSupport::TestCase
  KEY = :creator_harmonic_cap

  setup do
    @admin = create(:admin_user)
    @user = create(:user)
  end

  context "A grant" do
    should "raise the account's limit and be logged" do
      assert_difference(-> { ModAction.where(category: "user_perk_grant").count }, 1) do
        UserPerk.grant!(@user, KEY, value: 12, by: @admin)
      end

      assert_equal(12, @user.reload.perk_value(KEY))
      assert_equal(@user, ModAction.last.subject)
    end

    should "replace the one before it, keeping it as history" do
      first = UserPerk.grant!(@user, KEY, value: 12, by: @admin)
      UserPerk.grant!(@user, KEY, value: 8, by: @admin)

      assert_equal(8, @user.reload.perk_value(KEY))
      assert_equal(@admin, first.reload.revoked_by)
      assert_equal(2, @user.user_perks.count)
    end

    should "be an admin's alone" do
      assert_raises(User::PrivilegeError) { UserPerk.grant!(@user, KEY, value: 12, by: create(:moderator_user)) }
      assert_equal(0, UserPerk.count)
    end

    should "refuse a value that does not raise the default or passes the max" do
      [5, 26, nil].each do |value|
        assert_raises(ActiveRecord::RecordInvalid, value.inspect) { UserPerk.grant!(@user, KEY, value: value, by: @admin) }
      end
      assert_equal(0, ModAction.where(category: "user_perk_grant").count)
    end

    should "lapse when it expires" do
      UserPerk.grant!(@user, KEY, value: 12, by: @admin, expires_at: 1.day.from_now)

      travel(2.days) { assert_equal(5, @user.reload.perk_value(KEY)) }
    end
  end

  context "A revoke" do
    should "bring back the default and be logged" do
      UserPerk.grant!(@user, KEY, value: 12, by: @admin)

      assert_difference(-> { ModAction.where(category: "user_perk_revoke").count }, 1) do
        UserPerk.revoke!(@user, KEY, by: @admin)
      end
      assert_equal(5, @user.reload.perk_value(KEY))
    end

    should "do nothing, and log nothing, without a grant" do
      assert_nil(UserPerk.revoke!(@user, KEY, by: @admin))
      assert_equal(0, ModAction.where(category: "user_perk_revoke").count)
    end
  end

  context "Good standing" do
    setup do
      UserPerk.grant!(@user, KEY, value: 12, by: @admin)
    end

    should "be required: a restricted account gets the default" do
      @user.update_columns(level: User::Levels::RESTRICTED) # rubocop:disable Rails/SkipsModelValidations

      assert_equal(5, @user.reload.perk_value(KEY))
    end

    should "be required: a banned account gets the default, and its grant back when the ban ends" do
      ban = create(:ban, user: @user, banner: @admin, duration: 1.day)

      assert_equal(5, @user.reload.perk_value(KEY))
      travel(2.days) { assert_equal(12, @user.reload.perk_value(KEY)) }
      ban.destroy!
    end

    should "be required: a deleted account gets the default" do
      @user.update_columns(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations

      assert_equal(5, @user.reload.perk_value(KEY))
    end
  end

  should "give the default to an account without a grant, and a gallery the cap of its owner" do
    gallery = create(:creator_gallery, user: @user)

    assert_equal(5, gallery.harmonic_cap)
    UserPerk.grant!(@user, KEY, value: 9, by: @admin)

    assert_equal(9, gallery.reload.harmonic_cap)
    assert_equal(5, create(:creator_gallery).harmonic_cap)
  end
end
