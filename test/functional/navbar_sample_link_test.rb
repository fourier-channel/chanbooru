require "test_helper"

# The Sample link is the only route into the curation surface from inside this
# site, and from inside Technetium there is no other way in at all. If it does
# not render for the owner, the surface is unreachable for the one person
# entitled to it -- so this renders a REAL page in a REAL request and looks at
# the HTML, rather than testing the predicate in isolation.
#
# It was written after the link failed to appear for the owner in production.
# The template asked `CurrentUser.user`, a thread-local, while the component is
# handed its user explicitly as `current_user`; every other line in that
# template uses the latter.
class NavbarSampleLinkTest < ActionDispatch::IntegrationTest
  context "the Sample nav link" do
    setup do
      @owner = travel_to(1.month.ago) { create(:owner_user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
      @member = travel_to(1.month.ago) { create(:user) }
    end

    should "render for the owner" do
      get_auth root_path, @owner

      assert_response :success
      assert_match(%r{href="/sample/"}, response.body,
                   "the owner must have a way into the curation surface")
    end

    should "not render for an admin while the surface is owner-only" do
      get_auth root_path, @admin

      assert_response :success
      assert_no_match(%r{href="/sample/"}, response.body)
    end

    should "not render for an ordinary member" do
      get_auth root_path, @member

      assert_response :success
      assert_no_match(%r{href="/sample/"}, response.body)
    end

    should "not render for an anonymous visitor" do
      get root_path

      assert_response :success
      assert_no_match(%r{href="/sample/"}, response.body)
    end
  end
end
