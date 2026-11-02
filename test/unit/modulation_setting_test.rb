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
      assert_includes(ModulationSetting::PANEL_KEYS, "creator_about_boxes")
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

    # Operator, 2026-11-02: each About box opened, closed and resized per
    # viewer, one choice for every gallery. A box the viewer never touched is
    # open at its content's height, so nothing is stored for it.
    context "creator_about_boxes" do
      should "default to no opinion about any box" do
        assert_equal({}, ModulationSetting.defaults["creator_about_boxes"])
        assert_equal({}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])
        assert_equal({}, ModulationSetting.new(user: @user).creator_about_boxes)
      end

      should "merge each change into the box it names, leaving the others as they were" do
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => { "open" => false }})
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "blog" => { "h" => 320 }})
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => { "h" => "240" }})

        assert_equal({ "bio" => { "open" => false, "h" => 240 }, "blog" => { "h" => 320 }},
                     ModulationSetting.for_viewer(@user)["creator_about_boxes"])
        assert_equal({ "bio" => { "open" => false, "h" => 240 }, "blog" => { "h" => 320 }},
                     ModulationSetting.find_by!(user_id: @user.id).creator_about_boxes)
      end

      should "read an open flag's string forms, forget a height on nil, and forget a box on nil" do
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => { "open" => "false", "h" => 400 }, "blog" => { "open" => "true" }})
        assert_equal({ "bio" => { "open" => false, "h" => 400 }, "blog" => { "open" => true }}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])

        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => { "h" => nil }})
        assert_equal({ "bio" => { "open" => false }, "blog" => { "open" => true }}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])

        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => nil })
        assert_equal({ "blog" => { "open" => true }}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])
      end

      should "merge per box in the session for a signed-out viewer" do
        session = {}
        ModulationSetting.record!(User.anonymous, session, "creator_about_boxes" => { "characters" => { "open" => false }})
        ModulationSetting.record!(User.anonymous, session, "creator_about_boxes" => { "who-sees-the-posts" => { "h" => 80 }})

        assert_equal({ "characters" => { "open" => false }, "who-sees-the-posts" => { "h" => 80 }},
                     ModulationSetting.for_viewer(User.anonymous, session)["creator_about_boxes"])
        assert_equal(true, ModulationSetting.for_viewer(User.anonymous, session)["creator_about_open"])
        assert_equal(0, ModulationSetting.count)
      end

      should "refuse a shape it cannot keep, naming the shape it takes, and keep what was stored" do
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "bio" => { "h" => 300 }})

        [
          "bio",
          ["bio"],
          { "Bio Box" => { "open" => false }},
          { ("a" * 41) => { "open" => false }},
          { "bio" => "open" },
          { "bio" => { "open" => false, "width" => 3 }},
          { "bio" => { "h" => 79 }},
          { "bio" => { "h" => 2001 }},
          { "bio" => { "h" => "tall" }},
          { "bio" => { "h" => 120.5 }},
          (1..17).to_h { |i| ["box-#{i}", { "open" => false }] },
        ].each do |boxes|
          error = assert_raises(ModulationSetting::Refused) { ModulationSetting.record!(@user, nil, "creator_about_boxes" => boxes) }
          assert_match(/creator_about_boxes/, error.message)
          assert_match(/\{"bio": \{"open": false, "h": 320\}\}/, error.message)
        end

        assert_equal({ "bio" => { "h" => 300 }}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])
      end

      should "refuse a change that would keep more than 16 boxes, and take one that forgets a box" do
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => (1..16).to_h { |i| ["box-#{i}", { "open" => false }] })

        assert_raises(ModulationSetting::Refused) { ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "box-17" => { "open" => false }}) }
        ModulationSetting.record!(@user, nil, "creator_about_boxes" => { "box-1" => nil, "box-17" => { "open" => false }})

        assert_equal(16, ModulationSetting.for_viewer(@user)["creator_about_boxes"].size)
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
