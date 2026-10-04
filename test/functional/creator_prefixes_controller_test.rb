# frozen_string_literal: true

require "test_helper"

class CreatorPrefixesControllerTest < ActionDispatch::IntegrationTest
  context "The creator prefixes page" do
    should "list every prefix" do
      get creator_prefixes_path

      assert_response :success
      assert_select "td", text: "aichan_"
      assert_select "td", text: "Imageboard/web surface"
    end

    should "look a creator tag up to its provenance and target" do
      get creator_prefixes_path(tag: "aichan_selphdestruct", format: :json)

      assert_response :success
      assert_equal("Discord", response.parsed_body.dig("match", "provenance"))
      assert_equal("AIChan", response.parsed_body.dig("match", "target"))
    end

    should "say plainly when a tag carries no listed prefix" do
      get creator_prefixes_path(tag: "long_hair", format: :json)

      assert_response :success
      assert_nil(response.parsed_body["match"])
    end
  end
end
