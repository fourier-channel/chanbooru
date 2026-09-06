require "test_helper"

# Releasing an image from fourier-sampling's troll jail.
#
# Jailing deletes the booru post; releasing is meant to bring it back, and did
# not, from the day the feature shipped until 2026-09-06. Two independent
# refusals, both measured against production first:
#
#   1. the post could not be FOUND. A md5 search hides deleted posts below
#      deleted_post_visibility_level (ADMIN) and the sampling bot is an
#      Approver, so the lookup returned [] and the release gave up there.
#   2. the post could not be UNDELETED even with its id. Undeleting is
#      approving, and approving your own upload needs admin -- the bot uploaded
#      every post it has ever jailed. HTTP 422.
#
# This route does both halves server-side for exactly one case, and the
# narrowness is the design: a post that is deleted AND carries the jail tag.
# An ordinary moderator deletion is not reachable through it, whoever calls.
class FourierJailControllerTest < ActionDispatch::IntegrationTest
  JAIL_TAG = "troll_jail"

  # An md5 that is actually md5-shaped. The post factory uses
  # SecureRandom.hex(32), which is SIXTY-FOUR hex characters -- fine for a
  # uniqueness key, not a value this route would ever be handed, and it turns
  # every test here into an assertion about the malformed-input branch.
  def real_md5
    SecureRandom.hex(16)
  end

  def jailed_post(uploader)
    post = create(:post, uploader: uploader, md5: real_md5, tag_string: "scat #{JAIL_TAG}")
    post.update_columns(is_deleted: true)
    post
  end

  context "the jail release route" do
    setup do
      @bot = create(:approver_user)
    end

    should "undelete a jailed post" do
      post = jailed_post(@bot)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal({ "post_id" => post.id, "released" => true }, response.parsed_body)
      assert_equal(false, post.reload.is_deleted)
    end

    should "log the undeletion, so it shows up in the moderation record" do
      post = jailed_post(@bot)

      assert_difference(-> { ModAction.count }, 1) do
        post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }
      end

      assert_equal("post_undelete", ModAction.last.category)
      assert_equal(@bot, ModAction.last.creator)
    end

    # The reason this route has to exist at all. If this assertion ever starts
    # failing, the search CAN see deleted posts and the whole design should be
    # revisited rather than worked around.
    should "be reachable when the ordinary md5 search is not" do
      # The test environment lets everyone see deleted posts on purpose --
      # danbooru_local_config returns ANONYMOUS under Rails.env.test?, because
      # upstream's own posts_controller tests assert the permissive rule. So
      # the restriction has to be put back here, or this test measures the test
      # environment rather than production.
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      post = jailed_post(@bot)

      get_auth posts_path(format: :json), @bot, params: { tags: "md5:#{post.md5}" }
      assert_equal([], response.parsed_body)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }
      assert_response :success
      assert_equal(false, post.reload.is_deleted)
    end

    # The safety property. Everything else here is convenience; this is the one
    # that says the route cannot be turned into a general-purpose undelete.
    should "refuse a deleted post that was never jailed" do
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "scat")
      post.update_columns(is_deleted: true)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response 422
      assert_equal("not jailed", response.parsed_body["reason"])
      assert_equal(true, post.reload.is_deleted)
    end

    should "be idempotent for a post that is already active" do
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "scat #{JAIL_TAG}")

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal("already active", response.parsed_body["reason"])
    end

    # A missing post and a missing ROUTE must not look alike. The caller has to
    # tell "this booru has no such image" from "this booru is too old to have
    # the endpoint", and a bare 404 for both would make that impossible.
    should "report an unknown md5 in the body, not as a 404" do
      post_auth fourier_jail_release_path, @bot, params: { md5: "0" * 32 }

      assert_response :success
      assert_equal("no such post", response.parsed_body["reason"])
    end

    should "reject a malformed md5 with 422, keeping 404 free to mean 'no route'" do
      post_auth fourier_jail_release_path, @bot, params: { md5: "nothex" }

      assert_response 422
    end

    should "refuse anyone below approver" do
      post = jailed_post(@bot)

      post_auth fourier_jail_release_path, create(:user), params: { md5: post.md5 }

      assert_response 403
      assert_equal(true, post.reload.is_deleted)
    end

    should "refuse an anonymous caller" do
      post = jailed_post(@bot)

      post fourier_jail_release_path, params: { md5: post.md5 }

      assert_response 403
      assert_equal(true, post.reload.is_deleted)
    end
  end
end
