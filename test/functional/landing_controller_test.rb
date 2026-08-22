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
        assert_select ".modland-slide", minimum: 1
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
      should "return a fresh set as JSON" do
        get landing_slides_path(format: :json)

        assert_response :success
        slides = response.parsed_body["slides"]
        assert_operator(slides.size, :>, 0)
        assert(slides.all? { |s| s.key?("url") && s.key?("src") })
        # Same blacklist contract as the gallery cards; a showcase is the worst
        # place to be shown something the viewer asked never to see.
        assert(slides.all? { |s| s.key?("tags") && s.key?("rating") })
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
