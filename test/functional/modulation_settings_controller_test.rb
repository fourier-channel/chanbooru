# frozen_string_literal: true

require "test_helper"

# PATCH /modulation/settings: the one endpoint every Modulation view choice is
# remembered through, a row for a signed-in viewer and the session otherwise.
class ModulationSettingsControllerTest < ActionDispatch::IntegrationTest
  context "The modulation settings controller" do
    context "for a signed-in viewer" do
      setup do
        @user = create(:user)
      end

      should "remember the hero band's wheel scroll, and forget it again" do
        method_authenticated(:patch, modulation_settings_path, @user, params: { wheel_scroll: true }, as: :json)

        assert_response :success
        assert_equal(true, response.parsed_body["wheel_scroll"])
        assert_equal(true, ModulationSetting.find_by!(user_id: @user.id).wheel_scroll)

        method_authenticated(:patch, modulation_settings_path, @user, params: { wheel_scroll: false }, as: :json)

        assert_response :success
        assert_equal(false, response.parsed_body["wheel_scroll"])
        assert_equal(false, ModulationSetting.find_by!(user_id: @user.id).wheel_scroll)
      end

      should "remember a closed About, and leave the wheel alone" do
        method_authenticated(:patch, modulation_settings_path, @user, params: { creator_about_open: false }, as: :json)

        assert_response :success
        assert_equal(false, response.parsed_body["creator_about_open"])
        assert_equal(false, response.parsed_body["wheel_scroll"])
        assert_equal(false, ModulationSetting.for_viewer(@user)["creator_about_open"])
      end

      # A PATCH carries only the About box that changed; the rest stay.
      should "merge an About box's change into the viewer's boxes" do
        method_authenticated(:patch, modulation_settings_path, @user, params: { creator_about_boxes: { bio: { open: false }}}, as: :json)
        method_authenticated(:patch, modulation_settings_path, @user, params: { creator_about_boxes: { blog: { h: 320 }}}, as: :json)

        assert_response :success
        assert_equal({ "bio" => { "open" => false }, "blog" => { "h" => 320 }}, response.parsed_body["creator_about_boxes"])
        assert_equal({ "bio" => { "open" => false }, "blog" => { "h" => 320 }}, ModulationSetting.for_viewer(@user)["creator_about_boxes"])
        assert_equal(true, response.parsed_body["creator_about_open"])
      end

      should "refuse an About box it cannot keep with a 422 that names the shape, and keep the rest of the change out" do
        method_authenticated(:patch, modulation_settings_path, @user, params: { creator_about_boxes: { bio: { h: 5 }}, wheel_scroll: true }, as: :json)

        assert_response 422
        assert_match(/creator_about_boxes/, response.parsed_body["error"])
        assert_nil(ModulationSetting.find_by(user_id: @user.id))
      end
    end

    context "for a signed-out viewer" do
      should "keep the wheel scroll in the session, read back on the next request" do
        patch modulation_settings_path, params: { wheel_scroll: true }, as: :json

        assert_response :success
        assert_equal(true, response.parsed_body["wheel_scroll"])

        patch modulation_settings_path, params: { creator_about_open: false }, as: :json

        assert_response :success
        assert_equal(true, response.parsed_body["wheel_scroll"])
        assert_equal(false, response.parsed_body["creator_about_open"])
        assert_equal(0, ModulationSetting.count)

        patch modulation_settings_path, params: { wheel_scroll: false }, as: :json

        assert_equal(false, response.parsed_body["wheel_scroll"])
      end

      should "merge About boxes in the session, read back on the next request" do
        patch modulation_settings_path, params: { creator_about_boxes: { characters: { open: false }}}, as: :json
        assert_response :success

        patch modulation_settings_path, params: { creator_about_boxes: { characters: { h: 200 }, blog: { h: nil }}}, as: :json

        assert_response :success
        assert_equal({ "characters" => { "open" => false, "h" => 200 }}, response.parsed_body["creator_about_boxes"])
        assert_equal(0, ModulationSetting.count)
      end
    end
  end
end
