require "test_helper"

# The post page's ( jail | delete ) pill, ModulationModerationController.
#
# Into the jail only (operator ruling 2026-10-09: there is no booru-side way
# to release a jailed post; release happens only from the jail panel). Its
# jail-on leaves the proof the release route accepts -- the deletion made by
# the system user on the moderator's behalf -- and the post_jail row the
# panel reads (operator 2026-10-09: every booru-side jailing reaches the
# panel).
class ModulationModerationControllerTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"

  def pill(post, params)
    patch modulation_moderation_path(post), params: params, as: :json
  end

  context "The moderation pill" do
    setup do
      @moderator = create(:moderator_user)
      @uploader = create(:user)
      @post = create(:post, uploader: @uploader, tag_string: "landscape")
      login_as(@moderator)
    end

    should "jail a live post: the tag, and a deletion by the system user on the moderator's behalf" do
      pill(@post, { jail: true })

      assert_response :success
      assert_equal({ "jailed" => true, "deleted" => true }, response.parsed_body.slice("jailed", "deleted"))
      @post.reload
      assert @post.has_tag?(JAIL)
      assert_equal [User.system.id], @post.flags.succeeded.pluck(:creator_id)
      deletion = ModAction.where(subject: @post, category: "post_delete").sole
      assert_equal User.system, deletion.creator
      assert_equal "deleted post ##{@post.id}, reason: troll jail: moderator #{@moderator.name}, from the post page", deletion.description
      assert_equal User.system, ModAction.where(subject: @post, category: "post_jail").sole.creator
      assert @post.deletion_is_the_jails?
    end

    should "jail an already-deleted post without taking the deletion over" do
      as(@moderator) { @post.delete!("duplicate", user: @moderator) }

      pill(@post, { jail: true })

      assert_response :success
      @post.reload
      assert @post.has_tag?(JAIL)
      assert_equal [@moderator.id], @post.flags.succeeded.pluck(:creator_id)
      assert_not @post.deletion_is_the_jails?
      assert ModAction.exists?(subject: @post, category: "post_jail")
    end

    should "refuse jail-off on a jailed post, pointing at the jail panel" do
      pill(@post, { jail: true })

      pill(@post, { jail: false })

      assert_response 422
      assert_equal Post::JAILED_RELEASE_DOOR, response.parsed_body["refused"]
      assert @post.reload.has_tag?(JAIL)
      assert @post.is_deleted?
    end

    should "refuse delete-off on a jailed post, pointing at the jail panel" do
      pill(@post, { jail: true })
      login_as(create(:moderator_user))

      pill(@post, { deleted: false })

      assert_response 422
      assert_equal Post::JAILED_RELEASE_DOOR, response.parsed_body["refused"]
      assert @post.reload.is_deleted?
    end

    # The four production posts: the jail's deletion, the tag taken off by the
    # pill's old jail-off. Still jailed; still the panel's to release.
    should "refuse delete-off on a post whose tag is gone but whose deletion is the jail's" do
      bot = create(:approver_user, name: "sample")
      as(bot) { @post.delete!("troll jail: shock", user: bot) }

      pill(@post, { deleted: false })

      assert_response 422
      assert_equal({ "jailed" => true, "deleted" => true }, response.parsed_body.slice("jailed", "deleted"))
      assert @post.reload.is_deleted?
    end

    # Review of the 2026-10-10 build: a jailing the booru recorded stands on
    # the booru's own log (the post_jail row), not on the tag, so editing the
    # tag off a deleted post is no way out of the jail.
    should "keep a pill-jailed deleted post jailed after its tag is edited off" do
      as(@moderator) { @post.delete!("duplicate", user: @moderator) }
      pill(@post, { jail: true })
      assert_response :success
      as(create(:admin_user)) { @post.reload.update!(tag_string: "landscape") }
      assert_not @post.reload.has_tag?(JAIL)

      post_auth post_approvals_path(format: :json), create(:admin_user), params: { post_id: @post.id }
      assert_response 422
      assert_includes response.body, Post::JAILED_RELEASE_DOOR
      assert @post.reload.is_deleted?

      login_as(create(:moderator_user))
      pill(@post, { deleted: false })
      assert_response 422
      assert_equal Post::JAILED_RELEASE_DOOR, response.parsed_body["refused"]
      assert @post.reload.is_deleted?
    end

    should "report a pill jailing once, live or already deleted" do
      deleted = create(:post, tag_string: "landscape")
      as(@moderator) { deleted.delete!("duplicate", user: @moderator) }

      pill(@post, { jail: true })
      pill(deleted, { jail: true })

      assert_equal 1, ModAction.where(subject: @post, category: "post_jail").count
      descriptions = ModAction.where(subject: deleted, category: "post_jail").pluck(:description)
      assert_equal ["jailed post ##{deleted.id}, reason: troll jail: moderator #{@moderator.name}, from the post page"], descriptions
    end

    # A deleted post carrying the tag from before the booru reported its
    # jailings: jailed, and no row in the panel yet. The refusal says how
    # one gets there.
    should "name the past-jailings report when refusing a jailing the panel was never told of" do
      as(@moderator) { @post.delete!("duplicate", user: @moderator) }
      @post.update_columns(tag_string: "landscape #{JAIL}") # rubocop:disable Rails/SkipsModelValidations -- past the callbacks, as it stood before 2026-10-10

      login_as(create(:moderator_user))
      pill(@post.reload, { deleted: false })

      assert_response 422
      assert_includes response.parsed_body["refused"], "script/fourier_report_past_jailings.rb"
      assert @post.reload.is_deleted?
    end

    should "still delete and undelete an ordinary post" do
      pill(@post, { deleted: true })
      assert_response :success
      assert @post.reload.is_deleted?

      login_as(create(:moderator_user))
      pill(@post, { deleted: false })
      assert_response :success
      assert_not @post.reload.is_deleted?
    end
  end

  # No ordinary undelete door may undo the jail's deletion: the release route
  # is the only one (the "no booru-side release" ruling, 2026-10-09).
  context "An approval of a jailed post" do
    should "be refused, naming the jail panel" do
      bot = create(:approver_user, name: "sample")
      post = create(:post, uploader: bot, tag_string: "landscape")
      as(bot) { post.delete!("troll jail: shock", user: bot) }
      admin = create(:admin_user)

      post_auth post_approvals_path(format: :json), admin, params: { post_id: post.id }

      assert_response 422
      assert_includes response.body, Post::JAILED_RELEASE_DOOR
      assert post.reload.is_deleted?
    end
  end
end
