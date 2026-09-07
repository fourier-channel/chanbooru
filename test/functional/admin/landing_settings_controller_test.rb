require "test_helper"

# The front page is the shop window, so re-aiming it is an admin act.
class Admin::LandingSettingsControllerTest < ActionDispatch::IntegrationTest
  context "the landing setting panel" do
    setup do
      @admin = create(:admin_user)
      @user = create(:user)
    end

    should "not be reachable by an ordinary user" do
      get_auth admin_landing_setting_path, @user
      assert_response :forbidden
    end

    should "not be reachable anonymously" do
      # A flat refusal rather than a redirect to a login: this fork answers 403
      # here, which is the better answer -- an admin page should not advertise
      # itself to a stranger by inviting them to sign in.
      get admin_landing_setting_path
      assert_response :forbidden
    end

    should "render for an admin" do
      get_auth admin_landing_setting_path, @admin
      assert_response :success
    end

    should "change what the front page shows" do
      put_auth admin_landing_setting_path, @admin, params: {
        landing_setting: { board: "trash", fresh_only: "false", label: "From the bin" },
      }
      assert_redirected_to admin_landing_setting_path
      assert_equal "trash", LandingSetting.current.board
      assert_equal "From the bin", LandingShowcase.categories.find { |c| c[:key] == "new" }[:label]
    end

    should "refuse a board slug that is really a search, and say so" do
      put_auth admin_landing_setting_path, @admin, params: {
        landing_setting: { board: "b -no_train", label: "Sneaky" },
      }
      assert_response :unprocessable_entity
      refute_equal "b -no_train", LandingSetting.current.board
    end
  end
end
