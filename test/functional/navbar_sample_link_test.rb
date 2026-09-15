require "test_helper"

# The Sample link is the only route into the curation surface from inside this
# site, and from inside Technetium there is no other way in at all. If it does
# not render for the owner, the surface is unreachable for the one person
# entitled to it -- so this renders a REAL page in a REAL request and looks at
# the HTML, rather than testing the predicate in isolation.
#
# BOTH PRESETS, and that is the point of this file. chanbooru renders one of
# two navbars -- ModulationNavbarComponent is the live one, NavbarComponent is
# upstream's, kept for side-by-side testing -- and the TEST environment
# defaults to the historical preset while production defaults to modulation.
# An earlier version of this test asserted only the default and passed against
# the navbar nobody sees, while the live one showed an inert, greyed-out pill.
# A test that renders a different skin than production is not a test of
# production.
class NavbarSampleLinkTest < ActionDispatch::IntegrationTest
  # ?preset= is explicit and sticky for the session, which is how a test reaches
  # the skin it means to check rather than the one it inherits.
  #
  # Defined at CLASS level on purpose: shoulda-context instance_execs its
  # `should` blocks, so a `def` written inside `context` is not an instance
  # method and every test errors with NoMethodError.
  def nav_for(user, preset)
    if user
      get_auth root_path(preset: preset), user
    else
      get root_path(preset: preset)
    end
    assert_response :success
    response.body
  end

  context "the Sample nav link" do
    setup do
      @owner = travel_to(1.month.ago) { create(:owner_user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
      @member = travel_to(1.month.ago) { create(:user) }
    end

    %w[modulation historical].each do |preset|
      should "render for the owner in the #{preset} navbar" do
        assert_match(%r{href="/sample/"}, nav_for(@owner, preset),
                     "the owner must have a way into the curation surface in #{preset}")
      end

      should "not render for an admin in the #{preset} navbar" do
        assert_no_match(%r{href="/sample/"}, nav_for(@admin, preset))
      end

      should "not render for an ordinary member in the #{preset} navbar" do
        assert_no_match(%r{href="/sample/"}, nav_for(@member, preset))
      end

      should "not render for an anonymous visitor in the #{preset} navbar" do
        assert_no_match(%r{href="/sample/"}, nav_for(nil, preset))
      end
    end

    should "not ship an inert Sample pill any more" do
      # It was deliberately disabled until the surface was integrated. That
      # condition was met when the trailing-slash redirect landed, and a pill
      # that stays greyed after its stated blocker is gone is worse than no
      # pill: it reads as "broken" rather than "not yet".
      body = nav_for(@owner, "modulation")

      assert_no_match(/Not yet linked/, body)
    end

  end
end
