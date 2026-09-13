require "test_helper"

# The authorization the reverse proxy asks before serving any of /sample.
#
# This is the whole boundary for that surface. The proxy serves nothing unless
# this answers 2xx, and it copies one header out of the reply to decide which
# view the sampling app renders. If this is wrong, the wrongness is not a
# cosmetic one: the internal view reaches routes that jail an image, release
# one, apply jail policy, empty the junk bucket and steer acquisition.
#
# The sampling side enforces an allowlist keyed on that header, so these two
# test files are the two halves of one boundary and neither is sufficient alone.
class SampleAuthorizeTest < ActionDispatch::IntegrationTest
  context "the /sample authorization endpoint" do
    setup do
      @member = travel_to(1.month.ago) { create(:user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
      @owner = travel_to(1.month.ago) { create(:owner_user) }
    end

    should "refuse an anonymous visitor rather than give them the external view" do
      get fourier_sample_authorize_path

      assert_response :forbidden
      assert_nil(response.headers["X-Fourier-View"],
                 "a refusal must not also name a view")
    end

    should "give an ordinary member the external view" do
      get_auth fourier_sample_authorize_path, @member

      assert_response :no_content
      assert_equal("external", response.headers["X-Fourier-View"])
    end

    should "give an admin the internal view" do
      get_auth fourier_sample_authorize_path, @admin

      assert_response :no_content
      assert_equal("internal", response.headers["X-Fourier-View"])
    end

    should "give the owner the internal view" do
      get_auth fourier_sample_authorize_path, @owner

      assert_response :no_content
      assert_equal("internal", response.headers["X-Fourier-View"])
    end

    should "not promote a moderator, who moderates content rather than machinery" do
      moderator = travel_to(1.month.ago) { create(:moderator_user) }
      get_auth fourier_sample_authorize_path, moderator

      assert_response :no_content
      assert_equal("external", response.headers["X-Fourier-View"],
                   "moderator is deliberately not an internal viewer")
    end

    should "always answer with a view when it answers at all" do
      # The proxy copies this header and has no fallback. A 2xx without it
      # would leave the sampling app to choose, and its default is internal.
      get_auth fourier_sample_authorize_path, @member

      assert_response :success
      assert_includes(%w[internal external], response.headers["X-Fourier-View"])
    end
  end
end
