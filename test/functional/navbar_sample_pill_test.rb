require "test_helper"

# The Sample pill, which is deliberately inert until the surface is integrated.
#
# The thing being tested is not the styling. It is that a disabled entry has no
# href at all. A greyed-out <a> is still focusable, still in the tab order,
# still announced as a link and still followable by anyone who reads the
# markup -- the same shape of mistake as a CSS rule standing in for a security
# boundary, which this fork has already been bitten by elsewhere.
class NavbarSamplePillTest < ActionDispatch::IntegrationTest
  context "the Sample pill" do
    setup do
      @user = travel_to(1.month.ago) { create(:user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
    end

    should "appear for a signed-in viewer" do
      get_auth posts_path(preset: "modulation"), @user

      assert_response :success
      assert_select "#top.modnav .modnav-pill", text: /Sample/
    end

    should "carry no href, so it cannot be followed" do
      get_auth posts_path(preset: "modulation"), @user

      assert_response :success
      assert_select "#top.modnav .modnav-pill.is-disabled" do |pills|
        pill = pills.find { |p| p.text.include?("Sample") }
        assert_not_nil(pill, "the Sample pill should be the disabled one")
        assert_equal("span", pill.name, "a disabled entry must not be an anchor")
        assert_nil(pill["href"], "a disabled entry must have no href")
        assert_equal("true", pill["aria-disabled"])
      end
    end

    should "be inert for an admin too, since the page is not integrated yet" do
      get_auth posts_path(preset: "modulation"), @admin

      assert_response :success
      assert_select "#top.modnav .modnav-pill.is-disabled", text: /Sample/
    end

    should "not appear at all for an anonymous visitor" do
      get posts_path(preset: "modulation")

      assert_response :success
      assert_select "#top.modnav .modnav-pill", text: /Sample/, count: 0
    end

    should "leave the other pills as real links" do
      get_auth posts_path(preset: "modulation"), @user

      assert_response :success
      assert_select "#top.modnav a.modnav-pill", text: /Posts/
      assert_select "#top.modnav a.modnav-pill.is-disabled", count: 0,
                    message: "no anchor should ever carry the disabled class"
    end
  end
end
