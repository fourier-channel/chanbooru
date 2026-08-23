# frozen_string_literal: true

require "test_helper"

# Signup being closed is the mechanism holding 41chan shut before it opens, and
# it used to be a stylesheet: the form was greyed out with `opacity: 0.4;
# pointer-events: none` and a JS notice, while UserPolicy#create? still answered
# yes to any anonymous visitor. A POST straight to /users made a real account,
# and an account is what the media gate checks for.
#
# The config that was supposed to govern this (Danbooru.config.enable_signup?)
# existed and was read by nothing.
#
# These tests are here rather than in upstream's users_controller_test because
# enable_signup? is TRUE under test -- thirty-nine of upstream's own tests POST
# to /users and expect an account out the other end. So the closed case is
# stubbed on, explicitly, right here, which is the only place it is exercised.
class SignupClosedTest < ActionDispatch::IntegrationTest
  context "With signups closed" do
    setup do
      Danbooru.config.stubs(:enable_signup?).returns(false)
    end

    should "refuse to create an account" do
      assert_no_difference("User.count") do
        post users_path, params: { user: { name: "walkin", password: "hunter22", password_confirmation: "hunter22" }}
      end

      assert_response 403
    end

    should "refuse even when the request is otherwise perfectly valid" do
      # The CSS-only version stopped a browser and nothing else. This is the
      # shape of the request that used to work.
      assert_no_difference("User.count") do
        post users_path, params: {
          user: {
            name: "walkin",
            password: "hunter22",
            password_confirmation: "hunter22",
            email_address: { address: "walkin@example.com" },
          },
        }
      end

      assert_response 403
    end

    should "still serve the signup page, because that is where the visitor is told why" do
      get new_user_path

      assert_response :success
    end
  end

  context "With signups open" do
    setup do
      Danbooru.config.stubs(:enable_signup?).returns(true)
    end

    should "create an account" do
      assert_difference("User.count", 1) do
        post users_path, params: { user: { name: "walkin", password: "hunter22", password_confirmation: "hunter22" }}
      end
    end
  end
end
