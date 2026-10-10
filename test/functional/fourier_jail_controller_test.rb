require "test_helper"

# The jail panel's door into the booru (FourierJailController).
#
# POST /fourier_jail/release releases an image from fourier-sampling's troll
# jail: untag AND undelete, one act, and only a deletion the jail made --
# proved by WHO deleted (a jail account, under the name it held then), never
# by the reason text an approver types. GET lists the booru's own jailings
# for the panel. Both answer the jail panel's account alone (operator ruling
# 2026-10-09: release happens only from the jail panel, by the jail account).
#
# Why the route exists at all, measured against production on 2026-09-06:
# the md5 search hides deleted posts below ADMIN, and undeleting is approving,
# which refuses the bot's own uploads.
class FourierJailControllerTest < ActionDispatch::IntegrationTest
  JAIL_TAG = "troll_jail"

  # An md5 that is actually md5-shaped. The post factory uses
  # SecureRandom.hex(32), which is SIXTY-FOUR hex characters.
  def real_md5
    SecureRandom.hex(16)
  end

  # A post jailed the way sampling's jailSync jails one: the tag, then DELETE
  # /posts/:id as the jail account with "troll jail: <why>" (Post#delete!
  # writes the deletion's mod action under that account).
  def jailed_post(uploader, why: "shock", tags: "landscape #{JAIL_TAG}")
    post = create(:post, uploader: uploader, md5: real_md5, tag_string: tags)
    as(uploader) { post.delete!("troll jail: #{why}", user: uploader) }
    post.reload
  end

  context "the jail release route" do
    setup do
      # The jail panel's account, by the real list (fourier_jail_release_names).
      @bot = create(:approver_user, name: "sample")
    end

    should "undelete a jailed post and take the jail tag off, in one act" do
      post = jailed_post(@bot)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal({ "post_id" => post.id, "released" => true }, response.parsed_body)
      post.reload
      assert_equal(false, post.is_deleted)
      assert_not post.has_tag?(JAIL_TAG)
    end

    should "log the undeletion, so it shows up in the moderation record" do
      post = jailed_post(@bot)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_equal("post_undelete", ModAction.last.category)
      assert_equal(@bot, ModAction.last.creator)
    end

    # The reason this route has to exist at all.
    should "be reachable when the ordinary md5 search is not" do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      post = jailed_post(@bot)

      get_auth posts_path(format: :json), @bot, params: { tags: "md5:#{post.md5}" }
      assert_equal([], response.parsed_body)

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }
      assert_response :success
      assert_equal(false, post.reload.is_deleted)
    end

    # The four production posts (90197, 119048, 104280, 89787): jailed by
    # sampling, then the pill's old jail-off took the tag and left them
    # deleted. Their current deletion is still the jail's.
    should "release a deleted post without the tag whose current deletion is the jail's" do
      post = jailed_post(@bot)
      as(create(:moderator_user)) { post.update!(tag_string: "landscape") }

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal(true, response.parsed_body["released"])
      assert_equal(false, post.reload.is_deleted)
    end

    should "release a jailing the booru made itself (the system user's deletion)" do
      moderator = create(:moderator_user)
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")
      login_as(moderator)
      patch modulation_moderation_path(post), params: { jail: true }, as: :json
      assert_response :success
      assert post.reload.is_deleted?

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_equal(true, response.parsed_body["released"])
      assert_equal(false, post.reload.is_deleted)
    end

    # The safety property: never a general-purpose undelete.
    should "never undo a moderator's deletion, tagged or not" do
      moderator = create(:moderator_user)
      untagged = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")
      as(moderator) { untagged.delete!("duplicate", user: moderator) }

      post_auth fourier_jail_release_path, @bot, params: { md5: untagged.md5 }

      assert_response 422
      assert_equal(FourierJailController::NOT_THE_JAILS, response.parsed_body["reason"])
      assert_equal(true, untagged.reload.is_deleted)

      # Tagged on top of a moderator's deletion: the jail is lifted, the
      # deletion stands, and the caller is told so.
      tagged = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")
      as(moderator) { tagged.delete!("duplicate", user: moderator) }
      as(moderator) { tagged.update!(tag_string: "landscape #{JAIL_TAG}") }

      post_auth fourier_jail_release_path, @bot, params: { md5: tagged.md5 }

      assert_response 422
      assert_equal({ "deleted" => true, "jailed" => false }, response.parsed_body.slice("deleted", "jailed"))
      tagged.reload
      assert_equal(true, tagged.is_deleted)
      assert_not tagged.has_tag?(JAIL_TAG)
    end

    # A jailing the booru recorded on top of a moderator's deletion (the
    # pill's jail-on of a deleted post) stands on the post_jail row, tag or
    # no tag. The panel's release lifts it and closes it on the booru's log
    # (post_unjail), so the moderator's deletion is an ordinary one again.
    should "close a jailing it lifts from a moderator's deletion" do
      moderator = create(:moderator_user)
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")
      as(moderator) { post.delete!("duplicate", user: moderator) }
      login_as(moderator)
      patch modulation_moderation_path(post), params: { jail: true }, as: :json
      as(moderator) { post.reload.update!(tag_string: "landscape") }
      assert post.reload.jailed?

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response 422
      assert_equal({ "deleted" => true, "jailed" => false }, response.parsed_body.slice("deleted", "jailed"))
      assert_not post.reload.jailed?
      assert_equal(["post_unjail", @bot.id], ModAction.where(subject: post).order(:id).last.then { |row| [row.category, row.creator_id] })
      admin = create(:admin_user)
      as(admin) { PostApproval.create!(post: post, user: admin) }
      assert_not post.reload.is_deleted?
    end

    # Words prove nothing: an approver's deletion typed "troll jail: x" is an
    # ordinary deletion.
    should "not undo an approver's deletion whose reason imitates the jail's" do
      approver = create(:approver_user)
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape #{JAIL_TAG}")
      as(approver) { post.delete!("troll jail: shock", user: approver) }

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response 422
      assert_equal(true, post.reload.is_deleted)
    end

    should "not undo a deletion made after a human undeleted the jail's" do
      # An approver's undeletion as the booru allowed it before 2026-10-10
      # (PostApproval#approve_post's writes), which PostApproval now refuses.
      post = jailed_post(@bot, tags: "landscape")
      admin = create(:admin_user)
      as(admin) { post.update!(is_deleted: false, approver: admin) }
      ModAction.log("undeleted post ##{post.id}", :post_undelete, subject: post, user: admin)
      # Deleted again by the one deletion nothing logs -- the system user's
      # pruning -- so the jail's is still the latest logged deletion, and only
      # the undeletion after it says that deletion no longer stands.
      as(User.system) { post.reload.delete!("Unapproved in three days", user: User.system) }

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response 422
      assert_equal(true, post.reload.is_deleted)
    end

    # Who acted is judged by the name the account held WHEN it acted.
    should "still prove the jail's deletion after the jail account is renamed" do
      post = jailed_post(@bot)
      travel(1.minute) do
        UserNameChangeRequest.create!(user: @bot, original_name: @bot.name, desired_name: "sample_old")
        new_bot = create(:approver_user, name: "sample")

        post_auth fourier_jail_release_path, new_bot, params: { md5: post.md5 }
      end

      assert_equal(true, response.parsed_body["released"])
    end

    context "a legal hold" do
      should "be refused forever, tag and deletion untouched" do
        post = jailed_post(@bot, why: "radioactive")

        post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

        assert_response 422
        assert_equal(true, response.parsed_body["hold"])
        post.reload
        assert_equal(true, post.is_deleted)
        assert post.has_tag?(JAIL_TAG)
      end

      should "not be forged by an approver typing the words" do
        approver = create(:approver_user)
        post = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")
        as(approver) { post.delete!("troll jail: radioactive", user: approver) }
        admin = create(:admin_user)
        as(admin) { PostApproval.create!(post: post, user: admin) }
        as(@bot) { post.reload.update!(tag_string: "landscape #{JAIL_TAG}") }
        as(@bot) { post.reload.delete!("troll jail: shock", user: @bot) }

        post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

        assert_response :success
        assert_nil(response.parsed_body["hold"])
        assert_equal(false, post.reload.is_deleted)
      end
    end

    should "be idempotent for a post that is already active" do
      post = jailed_post(@bot)
      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }
      assert_equal(true, response.parsed_body["released"])

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal("already active", response.parsed_body["reason"])
    end

    should "refuse a live post that was never jailed" do
      post = create(:post, uploader: @bot, md5: real_md5, tag_string: "landscape")

      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }

      assert_response 422
      assert_equal("not jailed", response.parsed_body["reason"])
    end

    should "report an unknown md5 in the body, not as a 404" do
      post_auth fourier_jail_release_path, @bot, params: { md5: "0" * 32 }

      assert_response :success
      assert_equal("no such post", response.parsed_body["reason"])
    end

    should "reject a malformed md5 with 422, keeping 404 free to mean 'no route'" do
      post_auth fourier_jail_release_path, @bot, params: { md5: "nothex" }

      assert_response 422
    end

    # No booru-side release (operator ruling 2026-10-09): an approver, even an
    # admin, who is not the jail panel's account is refused.
    should "refuse every caller but the jail panel's account" do
      post = jailed_post(@bot)

      [create(:approver_user), create(:admin_user), create(:user)].each do |caller|
        post_auth fourier_jail_release_path, caller, params: { md5: post.md5 }
        assert_response 403
      end
      post fourier_jail_release_path, params: { md5: post.md5 }
      assert_response 403
      assert_equal(true, post.reload.is_deleted)
    end
  end

  # Production, measured 2026-10-10: the jail's account was renamed
  # sampling -> sample on 2026-09-14, and its earlier jailings were written
  # under the old name. They are still the jail's.
  context "a jail account renamed onto the list" do
    should "still prove the jailings it made under its old name" do
      bot = create(:approver_user, name: "sampling")
      post = jailed_post(bot)
      travel(1.minute) do
        UserNameChangeRequest.create!(user: bot, original_name: "sampling", desired_name: "sample")

        post_auth fourier_jail_release_path, bot.reload, params: { md5: post.md5 }
      end

      assert_equal(true, response.parsed_body["released"])
      assert_equal(false, post.reload.is_deleted)
    end
  end

  # The booru reports its own jailings to the panel (operator 2026-10-09).
  context "the jail events feed" do
    setup do
      @bot = create(:approver_user, name: "sample")
    end

    should "list the pill's and the banished-tag failsafe's jailings since a cursor" do
      moderator = create(:moderator_user)
      pilled = create(:post, md5: real_md5, tag_string: "landscape")
      login_as(moderator)
      patch modulation_moderation_path(pilled), params: { jail: true }, as: :json
      assert_response :success
      banished = as(create(:user)) { create(:post, md5: real_md5, tag_string: "landscape gore") }
      assert banished.reload.is_deleted?

      get_auth fourier_jail_release_path(format: :json), @bot

      assert_response :success
      events = response.parsed_body["events"]
      assert_equal([pilled.id, banished.id], events.pluck("post_id"))
      assert_equal(["pill moderator", "banished tag"], events.pluck("actor"))
      assert_equal(moderator.name, events.first["moderator"])
      assert_equal(pilled.md5, events.first["md5"])
      assert_equal([true, true], events.pluck("jailed"))
      assert_includes(events.last["tags"], JAIL_TAG)

      travel(FourierJailController::SETTLE + 1.second) do
        get_auth fourier_jail_release_path(format: :json), @bot
        get_auth fourier_jail_release_path(format: :json), @bot, params: { since: response.parsed_body["cursor"] }
      end
      assert_equal([], response.parsed_body["events"])
    end

    # Every way into "deleted, carrying troll_jail" is a booru-side jailing
    # and reaches the panel (operator 2026-10-09; review of the 2026-10-10
    # build): the tag added to a deleted post, and a tagged post deleted. The
    # jail's own deletion is not reported back to the jail.
    should "report the jail tag added to a deleted post, and a tagged post deleted, but not the jail's own" do
      moderator = create(:moderator_user)
      approver = create(:approver_user)
      tagged_later = create(:post, md5: real_md5, tag_string: "landscape")
      as(moderator) { tagged_later.delete!("duplicate", user: moderator) }
      as(approver) { tagged_later.reload.update!(tag_string: "landscape #{JAIL_TAG}") }
      deleted_later = create(:post, md5: real_md5, tag_string: "landscape #{JAIL_TAG}")
      as(moderator) { deleted_later.delete!("off topic", user: moderator) }
      jailed_post(@bot)

      get_auth fourier_jail_release_path(format: :json), @bot

      events = response.parsed_body["events"]
      assert_equal([tagged_later.id, deleted_later.id], events.pluck("post_id"))
      assert_equal(["booru user", "booru user"], events.pluck("actor"))
      assert_equal([approver.name, moderator.name], events.pluck("moderator"))
      assert_equal([true, true], events.pluck("jailed"))
    end

    # Ids are handed out at INSERT and rows become visible at COMMIT, so a
    # row may appear below a cursor already read past (review of the
    # 2026-10-10 build). A row younger than the settle window is listed, but
    # the cursor stays before it until it is older.
    should "hold the cursor before a row still inside the settle window" do
      post = as(create(:user)) { create(:post, md5: real_md5, tag_string: "landscape gore") }
      row = ModAction.where(subject: post, category: "post_jail").sole

      get_auth fourier_jail_release_path(format: :json), @bot, params: { since: 0 }
      assert_equal([post.id], response.parsed_body["events"].pluck("post_id"))
      assert_equal(0, response.parsed_body["cursor"])
      assert_equal(false, response.parsed_body["more"])

      travel(FourierJailController::SETTLE + 1.second) do
        get_auth fourier_jail_release_path(format: :json), @bot, params: { since: 0 }
      end
      assert_equal(row.id, response.parsed_body["cursor"])
    end

    should "say a released jailing is no longer jailed" do
      post = as(create(:user)) { create(:post, md5: real_md5, tag_string: "landscape gore") }
      post_auth fourier_jail_release_path, @bot, params: { md5: post.md5 }
      assert_equal(true, response.parsed_body["released"])

      get_auth fourier_jail_release_path(format: :json), @bot

      assert_equal([false], response.parsed_body["events"].pluck("jailed"))
    end

    should "refuse every caller but the jail panel's account" do
      [create(:approver_user), create(:admin_user)].each do |caller|
        get_auth fourier_jail_release_path(format: :json), caller
        assert_response 403
      end
    end
  end
end
