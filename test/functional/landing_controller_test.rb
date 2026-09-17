require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  context "The landing controller" do
    setup do
      @user = travel_to(1.month.ago) { create(:user) }
      @posts = as(@user) { create_list(:post, 3, tag_string: "aaaa") }
    end

    context "show action" do
      should "render for an anonymous visitor" do
        get root_path

        assert_response :success
        assert_select ".modland", 1
        assert_select ".modland-ride .mod-stage", 1
        # The belt is served EMPTY and filled by the script, because every cell
        # is a node it owns and moves rather than re-renders. Server-rendering
        # cells here would only give it something to discard on its first frame.
        assert_select ".modland-ride .mod-belt", 1
        assert_select ".mod-belt .mod-cell", 0
        assert_select ".modland-poolitem", minimum: 1
      end

      should "offer the categories as one segmented control" do
        get root_path

        assert_response :success
        assert_select ".modland-tabs", 1
        assert_select ".modland-tab", minimum: 1
        assert_select ".modland-tab.is-active", 1
        assert_select ".modland-arrow", 2
      end

      # The carousel builds its cells from the payload, so the credit travels in
      # the payload rather than on the markup.
      should "carry the credit in the payload" do
        get root_path

        config = JSON.parse(css_select(".modland").first["data-config"])
        slides = config["categories"].flat_map { it["slides"] }

        assert_operator(slides.size, :>, 0)
        assert(slides.any? { it.dig("creator", "name").present? }, "no slide named a creator")
      end

      # The blacklist matches on ELEMENTS. The carousel draws from the payload,
      # so every slide also exists as a hidden element for the blacklist to mark
      # -- without it the filter simply would not apply to this page.
      should "expose every slide to the blacklist" do
        get root_path

        config = JSON.parse(css_select(".modland").first["data-config"])
        expected = config["categories"].sum { it["slides"].size }

        assert_select ".modland-poolitem[data-tags][data-rating]", expected
      end

      # Present but hidden: it must never be on screen until the reader has
      # actually taken over, or it is just clutter offering to fix nothing.
      should "keep the resume control hidden until it is needed" do
        get root_path

        assert_select "[data-region=resume][hidden]", 1
        assert_select ".modland-resume-label", text: "The ride never ends."
      end

      should "render for a signed-in user" do
        get_auth root_path, @user

        assert_response :success
        assert_select ".modland", 1
      end

      # A landing page that renders empty boxes on a new site is worse than one
      # that renders nothing, so every section asks before taking up space.
      should "omit the creator sections when there is nothing to show" do
        CreatorGallery.delete_all

        get root_path

        assert_response :success
        assert_select ".modland-feature", 0
        assert_select ".modland-promoted", 0
        assert_select ".modland-enter", 1
      end

      should "show the promoted row" do
        # CREATOR OF THE MONTH IS GONE FROM THIS PAGE, 2026-09-17, by operator
        # ruling -- the idea moved into the carousel as the plural "Featured
        # Creators" row, configured by artist tags. This used to assert
        # ".modland-feature-title" and that the featured gallery was not
        # repeated in the row beneath itself; there is no row above it now.
        # featured_at is still SET here on purpose: it must no longer change
        # what the page renders, and a fixture that never sets it could not
        # show that.
        create(:creator_gallery, slug: "feat", matrix_id: "@feat:example.com", title: "Feature", featured_at: 1.hour.ago, promoted_at: 1.hour.ago)
        create(:creator_gallery, slug: "promo", matrix_id: "@promo:example.com", title: "Promo", promoted_at: 2.hours.ago)

        get root_path

        assert_select ".modland-feature", 0
        # BOTH appear now. The row used to exclude whichever gallery was the
        # current feature, so this fixture rendered ONE card; the exclusion is
        # gone with the section that justified it, and LandingShowcase never
        # applied it anyway -- which is how the carousel row and this row could
        # draw from different sets of six. See CreatorGallery.landing_promoted.
        assert_select ".modland-promoted-card", 2
        assert_select ".modland-promoted-name", text: "Promo"
        assert_select ".modland-promoted-name", text: "Feature"
      end

      # featured_at is PARKED, not live: the section it fed is gone and nothing
      # on the landing page reads this column. The ordering rule is still
      # asserted, because the column is kept for pinning a gallery to the
      # Featured Creators row later, and an ordering nobody checks is one that
      # will be wrong the day it is finally used.
      #
      # The RENDERING half of this asserted ".modland-feature-title" and was
      # MISSED when that section was removed one commit ago. The suite cannot
      # be run on this box -- DATABASE_URL points at production -- so reading
      # the tests is the only check there is, and one read was not enough.
      should "treat the most recently featured gallery as the current one" do
        create(:creator_gallery, slug: "old", matrix_id: "@old:example.com", title: "Old", featured_at: 2.months.ago)
        create(:creator_gallery, slug: "now", matrix_id: "@now:example.com", title: "Now", featured_at: 1.day.ago)

        assert_equal("now", CreatorGallery.current_feature.slug)

        get root_path
        assert_select ".modland-feature", 0
      end
    end

    context "slides action" do
      should "return the categories as JSON" do
        get landing_slides_path(format: :json)

        assert_response :success
        categories = response.parsed_body["categories"]
        assert_operator(categories.size, :>, 0)
        assert(categories.all? { |c| c.key?("key") && c.key?("label") && c["slides"].present? })

        slides = categories.flat_map { |c| c["slides"] }
        assert(slides.all? { |s| s.key?("url") && s.key?("src") })
        # Same blacklist contract as the gallery cards; a showcase is the worst
        # place to be shown something the viewer asked never to see.
        assert(slides.all? { |s| s.key?("tags") && s.key?("rating") })
      end

      should "name a creator and a platform where it can" do
        categories = LandingShowcase.new(viewer: User.anonymous).categories
        slides = categories.flat_map { it[:slides] }

        assert(slides.any? { it[:creator].present? }, "no slide named a creator")
        assert(slides.all? { it.key?(:platform) }, "platform must always be present, even when nil")
      end
    end

    context "the remembered preference" do
      should "default to showing the landing page" do
        get root_path

        assert_response :success
        assert_select ".modland", 1
      end

      should "send a visitor straight to the gallery once they choose it" do
        post landing_preference_path, params: { landing: "gallery" }
        assert_redirected_to posts_path

        get root_path
        assert_redirected_to posts_path
      end

      # Otherwise the preference is a trapdoor: no way back to the page that
      # offers the control that would undo it.
      should "still show the landing page on request after choosing the gallery" do
        post landing_preference_path, params: { landing: "gallery" }

        get root_path(show: 1)

        assert_response :success
        assert_select ".modland", 1
      end

      should "let the choice be reversed" do
        post landing_preference_path, params: { landing: "gallery" }
        post landing_preference_path, params: { landing: "landing" }

        get root_path
        assert_response :success
        assert_select ".modland", 1
      end
    end
  end
end
