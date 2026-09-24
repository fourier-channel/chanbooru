require "test_helper"

# The Sample pill in the LIVE navbar, ModulationNavbarComponent.
#
# This file was written 2026-09-13, when the pill went in deliberately inert
# for every signed-in viewer, and it pinned exactly that. On 2026-09-15
# (9d58b53d3) the pill was LIT, because its stated blocker -- the
# trailing-slash defect -- had been fixed at the edge, and made OWNER ONLY
# (operator ruling 2026-09-14), because SampleController#authorize now refuses
# everything below owner and a nav entry pointing at a shut door contradicts
# the boundary. This file went on asserting the inert pill for nine days.
#
# navbar_sample_link_test.rb pins the href in both presets by matching the
# page body. This file pins the PILL: the element in #top.modnav, lit, and
# absent for everyone the surface refuses.
class NavbarSamplePillTest < ActionDispatch::IntegrationTest
  context "the Sample pill" do
    setup do
      @owner = travel_to(1.month.ago) { create(:owner_user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
      @user = travel_to(1.month.ago) { create(:user) }
    end

    should "be a lit link to the curation surface for the owner" do
      get_auth posts_path(preset: "modulation"), @owner

      assert_response :success
      assert_select "#top.modnav a.modnav-pill[href='/sample/']", text: /Sample/, count: 1
      assert_select "#top.modnav .modnav-pill.is-disabled", text: /Sample/, count: 0,
                                                            message: "the pill was lit on 2026-09-15 and must not go back to inert"
    end

    should "not appear for an admin, because the surface is owner-only" do
      get_auth posts_path(preset: "modulation"), @admin

      assert_response :success
      assert_select "#top.modnav .modnav-pill", text: /Sample/, count: 0
    end

    should "not appear for an ordinary member" do
      get_auth posts_path(preset: "modulation"), @user

      assert_response :success
      assert_select "#top.modnav .modnav-pill", text: /Sample/, count: 0
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

# The contract this file was first written for, which outlived the pill.
#
# The template still renders a disabled entry, and no entry uses it today --
# so it is pinned here by rendering the component with one, and the next entry
# that goes in inert inherits a tested contract rather than a comment.
#
# The thing being tested is not the styling. It is that a disabled entry has no
# href at all. A greyed-out <a> is still focusable, still in the tab order,
# still announced as a link and still followable by anyone who reads the
# markup -- the same shape of mistake as a CSS rule standing in for a security
# boundary, which this fork has already been bitten by elsewhere.
class NavbarDisabledEntryTest < ViewComponent::TestCase
  context "a disabled navbar entry" do
    should "render as a span with no href, so it cannot be followed" do
      component = ModulationNavbarComponent.new(current_user: create(:user))
      inert = { label: "Inert", category: "meta", disabled: true, disabled_reason: "Not yet linked" }
      component.define_singleton_method(:entries) { [inert] }

      render_inline(component)

      assert_css("#top.modnav span#modnav-inert.modnav-pill.is-disabled[aria-disabled='true']", text: "Inert")
      assert_no_css("#modnav-inert[href]")
      # A disabled entry must not be an anchor, whatever it looks like.
      assert_no_css("#top.modnav a.modnav-pill")
    end
  end
end
