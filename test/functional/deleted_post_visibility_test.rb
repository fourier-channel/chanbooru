# frozen_string_literal: true

require "test_helper"

# Deleted posts do not exist, as far as an ordinary account is concerned.
#
# Upstream's rule is "anyone who asks": the account preference defaults to off,
# but the same gate ORs in "did the search say status:deleted", so on a stock
# Danbooru a signed-out visitor can list every deleted post by typing it. That
# is a fair default for a booru whose deletions are routine moderation, and the
# wrong one here.
class DeletedPostVisibilityTest < ActionDispatch::IntegrationTest
  def api_attrs(user, post)
    PostPolicy.new(user, post).api_attributes
  end

  def cards_for(id)
    css_select(".modgal-card[data-id='#{id}']").size
  end

  context "Deleted posts" do
    setup do
      # Upstream's default is left in place for the inherited suite; this is the
      # fork's rule, asserted where it is chosen.
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      @visible = create(:post, tag_string: "landscape")
      @deleted = create(:post, tag_string: "landscape")
      @deleted.update!(is_deleted: true)
    end

    should "not appear for a signed-out visitor searching status:deleted" do
      # The hole the settings toggle never covered, and the reason removing it
      # would not have been enough.
      get posts_path, params: { preset: "modulation", tags: "status:deleted" }

      assert_response :success
      assert_equal(0, cards_for(@deleted.id))
    end

    should "not appear for a member searching status:deleted" do
      get_auth posts_path, create(:user), params: { preset: "modulation", tags: "status:deleted" }

      assert_response :success
      assert_equal(0, cards_for(@deleted.id))
    end

    should "not appear for a member who has switched the preference on" do
      # The preference is the viewer asking. It cannot be what decides.
      member = create(:user)
      member.update!(show_deleted_posts: true)

      get_auth posts_path, member, params: { preset: "modulation" }

      assert_response :success
      assert_equal(0, cards_for(@deleted.id))
    end

    should "not appear for a moderator" do
      get_auth posts_path, create(:moderator_user), params: { preset: "modulation", tags: "status:deleted" }

      assert_response :success
      assert_equal(0, cards_for(@deleted.id))
    end

    should "appear for an admin who asks" do
      admin = create(:admin_user)
      admin.update!(show_deleted_posts: true)

      get_auth posts_path, admin, params: { preset: "modulation" }

      assert_response :success
      assert_equal(1, cards_for(@deleted.id))
    end

    should "still show ordinary posts to everyone" do
      get posts_path, params: { preset: "modulation" }

      assert_response :success
      assert_equal(1, cards_for(@visible.id))
    end
  end

  context "A deleted post's file identifiers" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      @uploader = create(:user)
      @deleted = create(:post, uploader: @uploader)
      @deleted.update!(is_deleted: true)
    end

    should "not be handed to a signed-out visitor" do
      # fourier-auth stops anonymous at the media gate anyway. This is about not
      # publishing the identifier in the first place.
      assert_not_includes(api_attrs(User.anonymous, @deleted), :md5)
      assert_not_includes(api_attrs(User.anonymous, @deleted), :file_url)
    end

    should "not be handed to an ordinary signed-in account" do
      # The case that mattered: a signed-in account HAS a session that satisfies
      # the media gate, so for them the md5 printed on the page was the lock.
      assert_not_includes(api_attrs(create(:user), @deleted), :md5)
      assert_not_includes(api_attrs(create(:user), @deleted), :file_url)
    end

    should "still be handed to the uploader, so they can appeal" do
      assert_includes(api_attrs(@uploader, @deleted), :md5)
      assert_includes(api_attrs(@uploader, @deleted), :file_url)
    end

    should "still be handed to an admin" do
      assert_includes(api_attrs(create(:admin_user), @deleted), :md5)
    end

    should "be unaffected for a post that is not deleted" do
      live = create(:post)

      assert_includes(PostPolicy.new(create(:user), live).api_attributes, :md5)
      assert_includes(PostPolicy.new(create(:user), live).api_attributes, :file_url)
    end
  end

  context "The settings page" do
    setup { Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN) }

    should "not offer the toggle to an account that cannot use it" do
      get_auth settings_path, create(:user)

      assert_response :success
      assert_select "input[type=checkbox][name=?]", "user[show_deleted_posts]", 0
    end

    should "offer it to an admin" do
      get_auth settings_path, create(:admin_user)

      assert_response :success
      assert_select "input[type=checkbox][name=?]", "user[show_deleted_posts]", 1
    end
  end
end
