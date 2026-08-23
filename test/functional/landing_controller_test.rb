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
        # The post view's stage, not a lookalike -- same classes, same mixin.
        assert_select ".modland-ride .mod-stage", 1
        assert_select ".mod-flank-col", 2
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
        slides = config["categories"].flat_map { _1["slides"] }

        assert_operator(slides.size, :>, 0)
        assert(slides.any? { _1.dig("creator", "name").present? }, "no slide named a creator")
      end

      # The blacklist matches on ELEMENTS. The carousel draws from the payload,
      # so every slide also exists as a hidden element for the blacklist to mark
      # -- without it the filter simply would not apply to this page.
      should "expose every slide to the blacklist" do
        get root_path

        config = JSON.parse(css_select(".modland").first["data-config"])
        expected = config["categories"].sum { _1["slides"].size }

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

      should "show the current feature and the promoted row" do
        feature = create(:creator_gallery, slug: "feat", matrix_id: "@feat:example.com", title: "Feature", featured_at: 1.hour.ago, promoted_at: 1.hour.ago)
        create(:creator_gallery, slug: "promo", matrix_id: "@promo:example.com", title: "Promo", promoted_at: 2.hours.ago)

        get root_path

        assert_select ".modland-feature-title", text: "Feature"
        # The feature is not repeated in the row beneath itself.
        assert_select ".modland-promoted-card", 1
        assert_select ".modland-promoted-name", text: "Promo"
        assert_not_nil(feature)
      end

      # Only the latest feature is current; setting a new one must not erase the
      # previous, and the previous must not still be shown.
      should "treat the most recently featured gallery as the current one" do
        create(:creator_gallery, slug: "old", matrix_id: "@old:example.com", title: "Old", featured_at: 2.months.ago)
        create(:creator_gallery, slug: "now", matrix_id: "@now:example.com", title: "Now", featured_at: 1.day.ago)

        assert_equal("now", CreatorGallery.current_feature.slug)

        get root_path
        assert_select ".modland-feature-title", text: "Now"
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
        slides = categories.flat_map { _1[:slides] }

        assert(slides.any? { _1[:creator].present? }, "no slide named a creator")
        assert(slides.all? { _1.key?(:platform) }, "platform must always be present, even when nil")
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
