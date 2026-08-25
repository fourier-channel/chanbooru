# frozen_string_literal: true

require "test_helper"

# Deleted posts must not appear in the default gallery.
#
# Upstream enforces this in PostPreviewComponent#render?, which simply declines
# to draw a deleted post. This fork's gallery replaced that component and took
# its layout without its guard, so deleted posts were rendering in the one view
# upstream is careful to keep them out of.
class ModulationGalleryDeletedTest < ActionDispatch::IntegrationTest
  context "The Modulation gallery" do
    setup do
      @user = create(:user)
      @visible = create(:post, tag_string: "landscape")
      @deleted = create(:post, tag_string: "landscape")
      @deleted.update!(is_deleted: true)
    end

    should "not draw a deleted post" do
      get posts_path, params: { preset: "modulation" }

      assert_response :success
      assert_select ".modgal-card[data-id=?]", @visible.id.to_s, 1
      assert_select ".modgal-card[data-id=?]", @deleted.id.to_s, 0
    end

    should "draw it for a viewer who asked to see deleted posts" do
      @user.update!(show_deleted_posts: true)

      get_auth posts_path, @user, params: { preset: "modulation" }

      assert_response :success
      assert_select ".modgal-card[data-id=?]", @deleted.id.to_s, 1
    end

    should "draw it when the search explicitly asks for deleted posts" do
      get posts_path, params: { preset: "modulation", tags: "status:deleted" }

      assert_response :success
      assert_select ".modgal-card[data-id=?]", @deleted.id.to_s, 1
    end
  end
end
