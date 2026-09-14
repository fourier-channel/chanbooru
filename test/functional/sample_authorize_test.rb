require "test_helper"

# The authorization the reverse proxy asks before serving any of /sample.
#
# OWNER ONLY as of 2026-09-14, while the surface is being shaped. Everything
# below owner is refused outright rather than downgraded to the external view.
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

    should "refuse an ordinary member while the surface is owner-only" do
      get_auth fourier_sample_authorize_path, @member

      assert_response :forbidden
      assert_nil(response.headers["X-Fourier-View"],
                 "a refusal must not also name a view")
    end

    should "refuse an admin, who was allowed in until 2026-09-14" do
      # Deliberately narrowed to owner while the surface is being shaped. If
      # this starts failing because someone widened it again, that is the
      # ruling changing and this test should change with it -- not quietly.
      get_auth fourier_sample_authorize_path, @admin

      assert_response :forbidden
    end

    should "refuse a moderator, who moderates content rather than machinery" do
      moderator = travel_to(1.month.ago) { create(:moderator_user) }
      get_auth fourier_sample_authorize_path, moderator

      assert_response :forbidden
    end

    should "give the owner the internal view" do
      get_auth fourier_sample_authorize_path, @owner

      assert_response :no_content
      assert_equal("internal", response.headers["X-Fourier-View"])
    end

    should "always answer with a view when it answers at all" do
      # The proxy copies this header and has no fallback. A 2xx without it
      # would leave the sampling app to choose, and its default is internal.
      get_auth fourier_sample_authorize_path, @owner

      assert_response :success
      assert_includes(%w[internal external], response.headers["X-Fourier-View"])
    end

    should "refuse every level below owner, so widening it cannot happen by accident" do
      # Enumerated rather than sampled: the levels are the whole domain of this
      # decision, and a test that checks three of them leaves the other five to
      # be discovered in production.
      %i[user gold_user builder_user approver_user moderator_user admin_user].each do |factory|
        actor = travel_to(1.month.ago) { create(factory) }
        get_auth fourier_sample_authorize_path, actor

        assert_response :forbidden, "#{factory} must not reach /sample while it is owner-only"
      end
    end
  end
end
