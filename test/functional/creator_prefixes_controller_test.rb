# frozen_string_literal: true

require "test_helper"

# Who sees the creator-prefix list (operator, 2026-10-07): members, not
# signed-out visitors, and each viewer only the prefixes they can see. The
# repo default list hides aichan_ (admins only).
class CreatorPrefixesControllerTest < ActionDispatch::IntegrationTest
  context "The creator prefixes page" do
    setup do
      CreatorPrefixes.reset!
      @member = create(:user)
      @admin = create(:admin_user)
    end

    should "not exist for a signed-out visitor" do
      get creator_prefixes_path
      assert_response 404
      get creator_prefixes_path(tag: "4chan_bob", format: :json)
      assert_response 404
    end

    should "show a member the prefixes they can see, and not a hidden one or the posting accounts" do
      get_auth creator_prefixes_path, @member
      assert_response :success
      assert_select "td", text: "Imageboard/web surface"
      assert_select "td", text: "aichan_", count: 0
      assert_select "td", text: "AIChan", count: 0
      assert_no_match(/Locked-tag editors/, response.body)
    end

    should "answer a member's lookup of a hidden prefix as an unlisted one" do
      get_auth creator_prefixes_path(tag: "aichan_selphdestruct", format: :json), @member
      assert_response :success
      assert_nil(response.parsed_body["match"])
      assert_nil(response.parsed_body["editors"])
      get_auth creator_prefixes_path(tag: "4chan_bob", format: :json), @member
      assert_equal("www.4chan.org", response.parsed_body.dig("match", "target"))
    end

    should "show an admin every prefix, the lookup and the posting accounts" do
      get_auth creator_prefixes_path, @admin
      assert_select "td", text: "aichan_"
      assert_match(/Locked-tag editors/, response.body)
      get_auth creator_prefixes_path(tag: "aichan_selphdestruct", format: :json), @admin
      assert_equal("Discord", response.parsed_body.dig("match", "provenance"))
      assert_equal("AIChan", response.parsed_body.dig("match", "target"))
    end

    should "say plainly when a tag carries no listed prefix" do
      get_auth creator_prefixes_path(tag: "long_hair", format: :json), @admin
      assert_response :success
      assert_nil(response.parsed_body["match"])
    end
  end
end
