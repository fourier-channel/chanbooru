# frozen_string_literal: true

require "test_helper"

# A SEARCH BOX THAT CANNOT WORK IS NOT OFFERED (2026-10-13). Signed out, /posts
# answers the newest posts and a featured creator's tag and nothing else
# (MembersOnly.anonymous_post_listing), and autocomplete is not a door open
# to a signed-out visitor -- so the gallery's search box 404'd on every
# keystroke (123 GET /autocomplete 404s in a day on production, two signed-out
# browsers), and its sort and board controls 404'd on every click. The rule
# stays; the controls are replaced, for a signed-out viewer, by one line
# saying how to sign in.
class SignedOutSearchBoxTest < ActionDispatch::IntegrationTest
  setup do
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    @uploader = create(:user)
    as(@uploader) { create(:post, tag_string: "landscape") }
  end

  context "the Modulation gallery" do
    should "offer a signed-out viewer a way to sign in, not a search box, sort or board filter" do
      get posts_path(preset: "modulation")

      assert_response :success
      assert_select "input[data-autocomplete='tag-query']", 0
      assert_select "select.modgal-sort", 0
      assert_select "nav.modgal-boards", 0
      assert_select ".modgal-signin a[href^='/login']", text: "sign in"
    end

    # The "In this search" pills are links to a tag search -- which a
    # signed-out viewer may open only for a featured creator's tag. Every
    # other pill is a label for them, not a link that 404s.
    should "draw a signed-out viewer's tag pills as labels, linking only a featured creator's tag" do
      LandingCategory.create!(key: "featured", label: "Featured Creators", enabled: true, position: 0,
                              kind: "tags", tags: ["featured_maker"], ordering: "new", fresh_only: false)
      as(@uploader) { create(:post, tag_string: "featured_maker") }

      get posts_path(preset: "modulation")

      assert_response :success
      assert_select ".mod-unitag a[data-tag='landscape']", 0
      assert_select ".mod-unitag span[data-tag='landscape']", 1
      assert_select ".mod-unitag a[data-tag='featured_maker'][href*='featured_maker']", 1
    end

    should "keep the search box, sort and board filter for a member" do
      get_auth posts_path(preset: "modulation"), create(:user)

      assert_response :success
      assert_select "input[data-autocomplete='tag-query']", 1
      assert_select "select.modgal-sort", 1
      assert_select "nav.modgal-boards", 1
      assert_select ".modgal-signin", 0
    end
  end

  # The post page's pills are drawn by its script from the payload: tag_links
  # nil means every pill links (a member); a list names the only tags a
  # signed-out viewer may open a search for -- a featured creator's.
  context "the post page's tag pills" do
    setup do
      LandingCategory.create!(key: "featured", label: "Featured Creators", enabled: true, position: 0,
                              kind: "tags", tags: ["featured_maker"], ordering: "new", fresh_only: false)
      @post = as(@uploader) { create(:post, tag_string: "featured_maker landscape") }
    end

    should "name only a featured creator's tag as a link for a signed-out viewer" do
      payload = as(User.anonymous) { ModulationPostComponent.new(post: @post, viewer: User.anonymous).payload }

      assert_equal(["featured_maker"], payload[:tag_links])
    end

    should "link every tag for a member" do
      member = create(:user)
      payload = as(member) { ModulationPostComponent.new(post: @post, viewer: member).payload }

      assert_nil(payload[:tag_links])
    end
  end

  context "the historical preset" do
    should "offer a signed-out viewer a way to sign in, not a search box" do
      get posts_path(preset: "historical")

      assert_response :success
      assert_select "#search-box input[data-autocomplete]", 0
      assert_select "#search-box a[href^='/login']", text: "sign in"
    end

    should "keep the search box for a member" do
      get_auth posts_path(preset: "historical"), create(:user)

      assert_response :success
      assert_select "#search-box input[data-autocomplete]", minimum: 1
    end
  end
end
