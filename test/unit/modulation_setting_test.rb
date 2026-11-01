# frozen_string_literal: true

require "test_helper"

# The viewer's Modulation view state: a row for a signed-in viewer, the same
# hash in the Rails session for a signed-out one.
class ModulationSettingTest < ActiveSupport::TestCase
  context "ModulationSetting" do
    setup do
      @user = create(:user)
    end

    # for_viewer slices the row by PANEL_KEYS, and the controller takes its
    # keys from the same list: a column missing from it never persists.
    should "carry the new view-state columns as panel keys, each with a default" do
      assert_includes(ModulationSetting::PANEL_KEYS, "wheel_scroll")
      assert_includes(ModulationSetting::PANEL_KEYS, "creator_about_open")
      assert_equal(ModulationSetting::PANEL_KEYS.sort, ModulationSetting.defaults.keys.sort)
      assert_empty(ModulationSetting::PANEL_KEYS - ModulationSetting.column_names)
    end

    context "wheel_scroll" do
      # Operator, 2026-11-01: the hero band's wheel "catches attempts to
      # scroll down the page". Off until the viewer turns it on.
      should "default to off" do
        assert_equal(false, ModulationSetting.defaults["wheel_scroll"])
        assert_equal(false, ModulationSetting.for_viewer(@user)["wheel_scroll"])
        assert_equal(false, ModulationSetting.new(user: @user).wheel_scroll)
      end

      should "persist for a signed-in viewer" do
        result = ModulationSetting.record!(@user, nil, "wheel_scroll" => true)

        assert_equal(true, result["wheel_scroll"])
        assert_equal(true, ModulationSetting.find_by!(user_id: @user.id).wheel_scroll)
        assert_equal(true, ModulationSetting.for_viewer(@user)["wheel_scroll"])
      end

      should "read the string forms a form or a query sends, and treat nil as no change" do
        ModulationSetting.record!(@user, nil, "wheel_scroll" => "true")
        assert_equal(true, ModulationSetting.for_viewer(@user)["wheel_scroll"])

        ModulationSetting.record!(@user, nil, "wheel_scroll" => nil)
        assert_equal(true, ModulationSetting.for_viewer(@user)["wheel_scroll"])

        ModulationSetting.record!(@user, nil, "wheel_scroll" => "false")
        assert_equal(false, ModulationSetting.for_viewer(@user)["wheel_scroll"])

        ModulationSetting.record!(@user, nil, "wheel_scroll" => true)
        ModulationSetting.record!(@user, nil, "wheel_scroll" => false)
        assert_equal(false, ModulationSetting.for_viewer(@user)["wheel_scroll"])
      end

      should "live in the session for a signed-out viewer" do
        session = {}
        ModulationSetting.record!(User.anonymous, session, "wheel_scroll" => true)

        assert_equal(true, session[ModulationSetting::SESSION_KEY]["wheel_scroll"])
        assert_equal(true, ModulationSetting.for_viewer(User.anonymous, session)["wheel_scroll"])
        assert_equal(false, ModulationSetting.for_viewer(User.anonymous, {})["wheel_scroll"])
        assert_equal(0, ModulationSetting.count)
      end
    end

    context "creator_about_open" do
      # Operator, 2026-11-01: "Start 'About' expanded by default".
      should "default to open" do
        assert_equal(true, ModulationSetting.defaults["creator_about_open"])
        assert_equal(true, ModulationSetting.for_viewer(@user)["creator_about_open"])
        assert_equal(true, ModulationSetting.new(user: @user).creator_about_open)
      end

      should "remember a close for a signed-in viewer, and an open again" do
        ModulationSetting.record!(@user, nil, "creator_about_open" => false)
        assert_equal(false, ModulationSetting.for_viewer(@user)["creator_about_open"])

        ModulationSetting.record!(@user, nil, "creator_about_open" => "true")
        assert_equal(true, ModulationSetting.for_viewer(@user)["creator_about_open"])
      end

      should "live in the session for a signed-out viewer" do
        session = {}
        ModulationSetting.record!(User.anonymous, session, "creator_about_open" => "false")

        assert_equal(false, ModulationSetting.for_viewer(User.anonymous, session)["creator_about_open"])
        assert_equal(0, ModulationSetting.count)
      end

      # A signed-in viewer's row created for another key must not close About.
      should "stay open on a row written for another key" do
        ModulationSetting.record!(@user, nil, "wheel_scroll" => true)

        assert_equal(true, ModulationSetting.for_viewer(@user)["creator_about_open"])
      end
    end

    should "drop a key it does not know" do
      result = ModulationSetting.record!(@user, nil, "wheel_scrol" => true, "nonsense" => "1")

      assert_not(result.key?("wheel_scrol"))
      assert_not(result.key?("nonsense"))
      assert_nil(ModulationSetting.find_by(user_id: @user.id))
    end
  end
end
