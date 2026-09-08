# frozen_string_literal: true

require "test_helper"

# The /upgrade page is ours now, and this is the only thing testing it.
#
# Upstream's user_upgrades_controller_test has 29 cases and every one of them
# begins `skip unless UserUpgrade.enabled?`. Upgrades are disabled on this site,
# so the whole file skips: it reports "29 tests, 0 assertions, 0 failures" and an
# exit code of 0 while asserting nothing at all. Retiring the sales page under
# that file would have been a change with no coverage reporting itself green.
#
# What is asserted here is the retirement as much as the replacement: the old
# page advertised a paid Gold tier, priced in dollars, through a Stripe checkout
# this site is not wired to. It must not come back by accident.
class FourierUpgradePageTest < ActionDispatch::IntegrationTest
  context "The /upgrade page" do
    should "render for an anonymous visitor" do
      get new_user_upgrade_path

      assert_response :success
    end

    should "render for a member" do
      get_auth new_user_upgrade_path, create(:user)

      assert_response :success
    end

    should "say the new thing" do
      get new_user_upgrade_path

      assert_response :success
      assert_match("Exciting things are coming to this space soon.", response.body)
      assert_match("This isn't the booru you're used to.", response.body)
      assert_match("I'm a poet and I was unaware of this fact.", response.body)
      assert_match("Stay tuned for more information as I make it up.", response.body)
    end

    should "not sell anything" do
      get new_user_upgrade_path

      assert_response :success
      # The retired page's load-bearing strings. Any of these reappearing means
      # the sales page is back.
      assert_no_match(/Upgrade to Gold/, response.body)
      assert_no_match(/feature-comparison/, response.body)
      assert_no_match(/Redeem upgrade code/, response.body)
      assert_no_match(/One time fee/, response.body)
      assert_no_match(/refund/i, response.body)
    end
  end
end
