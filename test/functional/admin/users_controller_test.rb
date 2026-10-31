require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  context "Admin::UsersController" do
    setup do
      @mod = create(:moderator_user)
      @user = create(:user)
      @admin = create(:admin_user)
    end

    context "#edit" do
      should "render for a mod" do
        get_auth edit_admin_user_path(@user), @mod
        assert_response :success
      end

      should "render for the owner" do
        get_auth edit_admin_user_path(create(:builder_user)), create(:owner_user)
        assert_response :success
      end

      should "not render for a regular user" do
        get_auth edit_admin_user_path(@user), @user
        assert_response 403
      end
    end

    context "#update" do
      context "when a moderator is promoting a basic member" do
        should "allow promoting the user to gold" do
          put_auth admin_user_path(@user), @mod, params: { user: { level: "30" }}

          assert_redirected_to(edit_admin_user_path(@user))
          assert_equal(30, @user.reload.level)
          assert_equal(true, @user.feedback.exists?)
          assert_equal(true, @user.dmails.received.exists?)
          assert_equal(true, @user.mod_actions.user_level_change.exists?)
          assert_match(%r{promoted "#{@user.name}":/users/#{@user.id} from Member to Gold}, ModAction.last.description)
          assert_equal(@user, ModAction.last.subject)
          assert_equal(@mod, ModAction.last.creator)
        end

        context "when promoting the user to an admin" do
          should "fail" do
            put_auth admin_user_path(@user), @mod, params: { user: { level: "50" }}

            assert_response(403)
            assert_equal(20, @user.reload.level)
            assert_equal(false, @user.feedback.exists?)
            assert_equal(false, @user.dmails.received.exists?)
            assert_equal(false, @user.mod_actions.user_level_change.exists?)
          end
        end

        context "when promoting the user to an invalid level" do
          should "fail" do
            put_auth admin_user_path(@user), @mod, params: { user: { level: "0" }}

            assert_response(403)
            assert_equal(20, @user.reload.level)
            assert_equal(false, @user.feedback.exists?)
            assert_equal(false, @user.dmails.received.exists?)
            assert_equal(false, @user.mod_actions.user_level_change.exists?)
          end
        end
      end

      context "when a moderator is demoting an admin" do
        should "fail" do
          put_auth admin_user_path(@admin), @mod, params: { user: { level: "30" }}

          assert_response(403)
          assert_equal(50, @admin.reload.level)
          assert_equal(false, @admin.feedback.exists?)
          assert_equal(false, @admin.dmails.received.exists?)
          assert_equal(false, @admin.mod_actions.user_level_change.exists?)
        end
      end

      context "when a non-moderator is trying to promote another user" do
        should "fail" do
          put_auth admin_user_path(@user), create(:approver_user), params: { user: { level: "30" }}

          assert_response(403)
          assert_equal(20, @user.reload.level)
          assert_equal(false, @user.feedback.exists?)
          assert_equal(false, @user.dmails.received.exists?)
          assert_equal(false, @user.mod_actions.user_level_change.exists?)
        end
      end
    end

    # Perks (CREATOR_TUNER.md sec 4.4): granted and revoked on this page by
    # an admin alone, each logged; a moderator who may promote sees no form.
    context "perks" do
      should "be shown with a form to an admin, and not to a moderator" do
        get_auth edit_admin_user_path(@user), @admin
        assert_select "#user-perks form", count: 1
        assert_select "#user-perks", text: /Creator Tuner harmonics\s+5/

        get_auth edit_admin_user_path(@user), @mod
        assert_select "#user-perks", count: 0
      end

      should "be granted and revoked by an admin, each logged" do
        put_auth admin_user_path(@user), @admin, params: { perk: { key: "creator_harmonic_cap", value: "9", expires_at: "2030-01-31" }}

        assert_redirected_to(edit_admin_user_path(@user))
        assert_equal("Granted: Creator Tuner harmonics 9 until 2030-01-31.", flash[:notice])
        assert_equal([9, Time.zone.parse("2030-01-31")], @user.user_perks.active.pick(:value, :expires_at))
        assert_equal("user_perk_grant", ModAction.last.category)

        put_auth admin_user_path(@user), @admin, params: { perk: { key: "creator_harmonic_cap", revoke: "1" }}

        assert_equal("Revoked: Creator Tuner harmonics is 5 again.", flash[:notice])
        assert_equal(5, @user.reload.perk_value(:creator_harmonic_cap))
        assert_equal("user_perk_revoke", ModAction.last.category)
      end

      should "refuse a value or date it cannot take, saying what it takes" do
        put_auth admin_user_path(@user), @admin, params: { perk: { key: "creator_harmonic_cap", value: "40" }}
        assert_equal("Not granted: Value must be a whole number from 6 to 25: 5 is everyone's already.", flash[:notice])

        put_auth admin_user_path(@user), @admin, params: { perk: { key: "creator_harmonic_cap", value: "9", expires_at: "soon" }}
        assert_equal("Not granted: the end date \"soon\" is not a date. Pick one with the date picker, or leave it empty for no end.", flash[:notice])
        assert_equal(0, UserPerk.count)
      end

      should "refuse a moderator" do
        put_auth admin_user_path(@user), @mod, params: { perk: { key: "creator_harmonic_cap", value: "9" }}

        assert_response(403)
        assert_equal(0, UserPerk.count)
      end

      should "refuse a perk it does not know, naming the ones it does -- and a moderator first" do
        put_auth admin_user_path(@user), @mod, params: { perk: { key: "nope", value: "9" }}
        assert_response(403)

        put_auth admin_user_path(@user), @admin, params: { perk: { key: "nope", value: "9" }}
        assert_redirected_to(edit_admin_user_path(@user))
        assert_equal("Not granted: there is no perk \"nope\". The perks are: creator_harmonic_cap.", flash[:notice])
        assert_equal(0, UserPerk.count)
      end
    end
  end
end
