require "test_helper"

# The Modulation interface -- this fork's UI, and what the site serves.
#
# Danbooru.config.default_experience_preset is "historical" in test on purpose
# (the reasoning is recorded there), so these tests ask for Modulation the same
# way a real request gets it: with the parameter. The one thing that cannot be
# asserted that way -- that the default OUTSIDE test is Modulation -- is
# asserted directly against the config.
class ModulationPresetTest < ActionDispatch::IntegrationTest
  context "The Modulation preset" do
    setup do
      @user = travel_to(1.month.ago) { create(:user) }
      @post = as(@user) { create(:post, tag_string: "aaaa bbbb") }
    end

    context "preset resolution" do
      should "be the default everywhere the site actually runs" do
        Rails.env.stubs(:test?).returns(false)

        assert_equal("modulation", Danbooru.config.default_experience_preset)
        assert_equal("modulation", ExperiencePreset.default_preset)
      end

      should "render Modulation when asked for it" do
        get posts_path(preset: "modulation")

        assert_response :success
        assert_select "body[data-preset=?]", "modulation"
        assert_select ".modgal", 1
      end

      should "render the upstream interface when asked for historical" do
        get posts_path(preset: "historical")

        assert_response :success
        assert_select "body[data-preset=?]", "historical"
        assert_select ".modgal", 0
      end

      should "remember an explicit preset for the session" do
        get posts_path(preset: "modulation")
        assert_select "body[data-preset=?]", "modulation"

        # No parameter this time: the session carries it.
        get posts_path
        assert_select "body[data-preset=?]", "modulation"
      end

      should "let an explicit preset leave again" do
        get posts_path(preset: "modulation")
        get posts_path(preset: "historical")

        assert_select "body[data-preset=?]", "historical"
      end

      # The post view links out to a few upstream pages it has no Modulation form
      # for yet. Without this, following one would switch the whole session to
      # the old interface and leave the viewer there.
      should "not remember a preset marked as this-request-only" do
        get post_path(@post, preset: "historical", preset_sticky: 0)
        assert_select "body[data-preset=?]", "historical"

        get posts_path
        assert_select "body[data-preset=?]", ExperiencePreset.default_preset
      end

      should "fall back to the default for an unrecognised preset, not error" do
        get posts_path(preset: "nonsense")

        assert_response :success
        assert_select "body[data-preset=?]", ExperiencePreset.default_preset
      end
    end

    context "the gallery" do
      should "render the themed index" do
        get posts_path(preset: "modulation")

        assert_response :success
        assert_select ".modgal-card", 1
        assert_select ".modgal-related-link"
      end

      # The blacklist is applied client-side, so these attributes ARE the
      # blacklist on this page: without them a viewer's rules match nothing.
      should "carry the blacklist attributes on every card" do
        get posts_path(preset: "modulation")

        assert_select ".modgal-card[data-tags][data-rating][data-uploader-id]", 1
      end

      should "render the blacklist controls" do
        get_auth posts_path(preset: "modulation"), @user

        assert_response :success
        assert_select "#blacklist-box", 1
      end
    end

    context "the post page" do
      should "render the single-cell view" do
        get post_path(@post, preset: "modulation")

        assert_response :success
        assert_select ".modulation", 1
        assert_select ".mod-stage", 1
      end

      # The action row is rendered by the client from the embedded payload -- the
      # same renderer that runs after a client-side navigation, so there is only
      # one of it. What the server owes is the region and the data; asserting on
      # the buttons here would be asserting that a browser ran.
      should "hand the client what the action row is built from" do
        get post_path(@post, preset: "modulation")

        assert_select "[data-region=actions]", 1
        payload = JSON.parse(css_select(".modulation").first["data-payload"])
        assert_not_nil(payload["score"])
        assert_not_nil(payload["fav"])
        assert_equal(2, payload["score"].values_at("total", "can_vote").size)
      end

      # The blacklist attaches here rather than to the article, so that hiding a
      # post hides its image and not the whole page.
      should "carry the blacklist attributes on the media container" do
        get post_path(@post, preset: "modulation")

        assert_select ".mod-blacklist-target[data-tags][data-rating]", 1
        assert_select ".modulation[data-tags]", 0
      end

      should "render the comment section" do
        get post_path(@post, preset: "modulation")

        assert_select "#mod-comments", 1
      end
    end

    context "the navigation payload" do
      should "carry everything the client re-renders a post from" do
        get post_modulation_path(post_id: @post.id), as: :json

        assert_response :success
        payload = response.parsed_body

        assert_equal(@post.id, payload["id"])
        assert_equal(@post.rating, payload["rating"])
        assert_equal("active", payload["status"])
        assert_not_nil(payload["score"])
        assert_not_nil(payload["fav"])
        assert_not_nil(payload["blacklist"])
        assert_not_nil(payload["more"])
      end

      # tag_string still holds the private creator tags; publishing it here
      # would put them in the page source of the default view.
      should "not publish private creator tags to an anonymous caller" do
        FourierTagSource.create!(post: @post, tag: "secret_prompt_tag", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false)
        @post.update!(tag_string: "aaaa bbbb secret_prompt_tag")

        get post_modulation_path(post_id: @post.id), as: :json

        assert_response :success
        assert_not_includes(response.parsed_body.dig("blacklist", "data-tags").to_s.split, "secret_prompt_tag")
        assert_includes(response.parsed_body.dig("blacklist", "data-tags").to_s.split, "aaaa")
      end

      # Regression: the comment section renders a form partial for anyone who may
      # comment, and partial lookup follows the request format -- so this path
      # 406'd for every logged-in viewer and nobody else.
      should "render for a logged-in viewer, who gets the comment form" do
        get_auth post_modulation_path(post_id: @post.id, format: :json), @user

        assert_response :success
        assert_match(/new-comment/, response.parsed_body["comments_html"].to_s)
      end

      # The other side of the same gate: withholding a creator's own tags from
      # them would make the feature useless rather than private.
      should "publish a private tag back to the creator who added it" do
        FourierTagSource.create!(post: @post, tag: "secret_prompt_tag", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false, added_by: @user.id)
        @post.update!(tag_string: "aaaa bbbb secret_prompt_tag")

        get_auth post_modulation_path(post_id: @post.id, format: :json), @user

        assert_response :success
        assert_includes(response.parsed_body.dig("blacklist", "data-tags").to_s.split, "secret_prompt_tag")
      end
    end
  end
end
