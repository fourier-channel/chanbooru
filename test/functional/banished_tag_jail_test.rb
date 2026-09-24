require "test_helper"

# THE BOORU'S OWN FAILSAFE (2026-09-24): a live post that GAINS a banished tag
# is jailed on the spot -- troll_jail added, then the post deleted -- by
# whatever door the tag came in.
#
# Until this, the only thing that ever jailed a post was fourier-sampling
# (src/booru/jailSync.ts), and measured on production the same day, five
# images it had jailed were still live: the jail landed a few seconds before
# the poster created the post, found nothing to act on, and nothing looked
# again. A rule enforced only by a client is enforced only when that client
# happens to be looking. This one is enforced where the tag lands.
#
# "Gains" is the word that matters. Releasing a jailed post takes troll_jail
# off and leaves the banished tag where it is -- that is what a release IS --
# so a rule keyed on "carries a banished tag" would put it straight back.
# Only a banished tag this save ADDED fires.
class BanishedTagJailTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  # The same words whichever banished tag it was: see "not name the banished
  # tag where anyone can read it" below.
  REASON = "troll jail: banished tag"

  def assert_jailed(post, tag)
    post.reload
    assert post.is_deleted?, "post ##{post.id} should be deleted; tags: #{post.tag_string}"
    assert post.has_tag?(JAIL), "post ##{post.id} should carry #{JAIL}; tags: #{post.tag_string}"
    assert post.has_tag?(tag), "post ##{post.id} should carry #{tag}; tags: #{post.tag_string}"
    assert_equal REASON, deletion_flags(post).last&.reason
  end

  def assert_live(post)
    post.reload
    assert_not post.is_deleted?, "post ##{post.id} should be live; tags: #{post.tag_string}"
  end

  # A deletion is recorded as a SUCCEEDED flag carrying the reason (Post#delete!);
  # it is what the post page reads the reason back from. No test here flags a
  # post any other way, so every succeeded flag is a deletion.
  def deletion_flags(post)
    post.flags.succeeded.order(:id)
  end

  def basic_auth(user)
    key = create(:api_key, user: user)
    { HTTP_AUTHORIZATION: "Basic #{::Base64.strict_encode64("#{user.name}:#{key.key}")}" }
  end

  # The upload route the posting bots use, as posts_controller_test drives it.
  def create_post!(user:, tag_string:)
    upload = build(:upload, uploader: user, media_asset_count: 1, status: "completed")
    asset = create(:upload_media_asset, upload: upload, media_asset: build(:media_asset))
    RateLimit.delete_all
    post_auth posts_path(format: :json), user, params: { upload_media_asset_id: asset.id, post: { rating: "q", source: asset.canonical_url, tag_string: tag_string }}
    Post.last
  end

  context "A live post that gains a banished tag" do
    setup do
      @member = create(:user)
      @post = as(@member) { create(:post, tag_string: "landscape", uploader: @member) }
    end

    should "be jailed when a member adds it through the JSON API" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape gore" }}

      assert_jailed(@post, "gore")
    end

    should "be jailed when it is added through the site's own edit form" do
      put_auth post_path(@post), @member, params: { post: { tag_string: "landscape gore", old_tag_string: "landscape" }}

      assert_jailed(@post, "gore")
    end

    # fourier-sampling's BooruClient#addTags, which the retag timer calls:
    # the new string PAIRED with the one it was based on, over Basic auth.
    should "be jailed when the retag bot adds it with its API key" do
      bot = create(:approver_user)

      put post_path(@post, format: :json), as: :json, headers: basic_auth(bot), params: { post: { tag_string: "landscape scat", old_tag_string: "landscape" }}

      assert_response :success
      assert_jailed(@post, "scat")
    end

    # fourier-tunnel's DanbooruClient#updateTags: the same pairing, from a
    # builder, with the payload as a plain JSON object.
    should "be jailed when fourier-tunnel adds it" do
      bot = create(:builder_user)

      put post_path(@post, format: :json), as: :json, headers: basic_auth(bot), params: { post: { tag_string: "landscape gore", old_tag_string: "landscape" }}

      assert_response :success
      assert_jailed(@post, "gore")
    end

    should "be jailed when an implication brings it in" do
      create(:tag_implication, antecedent_name: "entrails", consequent_name: "gore")

      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape entrails" }}

      assert_jailed(@post, "gore")
    end

    # The reason says WHY, not WHICH (review, 2026-09-24). A deletion flag's
    # reason and the mod log's description are read by anyone, signed in or
    # not (/post_flags, /mod_actions), and a banished NAME is shown to nobody
    # but an admin who has switched reveal on (TagBanishment). A reason that
    # named the tag published the names, and which post carried them.
    should "not name the banished tag where anyone can read it" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape scat gore" }}
      assert_jailed(@post, "gore")

      [post_flags_path(format: :json), mod_actions_path(format: :json)].each do |path|
        get path
        assert_response :success
        assert_includes response.body, "troll jail", "#{path} lists the jailing"
        assert_no_match(/gore|scat/, response.body, "#{path} names a banished tag")
      end
    end

    should "tag first and delete second, as the booru's own system user, and log it" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape gore" }}

      @post.reload
      assert_equal [User.system.id], deletion_flags(@post).pluck(:creator_id)
      action = ModAction.where(subject: @post, category: "post_delete").last
      assert_equal User.system, action.creator
      assert_equal "deleted post ##{@post.id}, reason: #{REASON}", action.description
    end

    should "jail exactly once, with one jail tag and one deletion" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape gore" }}

      @post.reload
      assert_equal 1, @post.tag_array.count(JAIL)
      assert_equal 1, deletion_flags(@post).count
    end

    should "finish a jailing whose delete half never landed" do
      # troll_jail on a live post: sampling tagged it and the delete failed.
      @post.update_columns(tag_string: "landscape #{JAIL}")

      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape #{JAIL} gore" }}

      assert_jailed(@post, "gore")
      assert_equal 1, @post.tag_array.count(JAIL)
      assert_equal 1, deletion_flags(@post).count
    end

    should "not fire for a tag that is not banished" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape sky" }}

      assert_live(@post)
      assert_not @post.has_tag?(JAIL)
      assert_equal 0, deletion_flags(@post).count
    end
  end

  context "A post created with a banished tag" do
    should "be jailed on arrival through the upload route the bots use" do
      bot = create(:builder_user)

      post = create_post!(user: bot, tag_string: "landscape gore")

      assert_response :success
      assert_jailed(post, "gore")
    end

    should "be jailed on arrival however it is created" do
      post = as(create(:user)) { create(:post, tag_string: "landscape feces") }

      assert_jailed(post, "feces")
    end
  end

  context "A post that is already deleted" do
    should "not be jailed, flagged or tagged again when it gains a banished tag" do
      admin = create(:admin_user)
      post = as(admin) { create(:post, tag_string: "landscape") }
      post.update_columns(is_deleted: true)

      put_auth post_path(post, format: :json), admin, as: :json, params: { post: { tag_string: "landscape gore" }}

      post.reload
      assert post.is_deleted?
      assert post.has_tag?("gore")
      assert_not post.has_tag?(JAIL)
      assert_equal 0, deletion_flags(post).count
    end
  end

  # The release path, end to end the way fourier-sampling walks it:
  # POST /fourier_jail/release undeletes, then a tag edit takes troll_jail
  # off. The banished tag stays on the post throughout. None of that is the
  # post GAINING anything, so none of it may jail it again.
  context "A jailed post that is released" do
    setup do
      @bot = create(:approver_user)
      @post = as(@bot) { create(:post, tag_string: "landscape gore", uploader: @bot, md5: SecureRandom.hex(16)) }
      assert_jailed(@post, "gore")
    end

    should "stay released through the release route and the untagging after it" do
      post_auth fourier_jail_release_path, @bot, params: { md5: @post.md5 }
      assert_response :success
      assert_live(@post)

      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore" }}
      assert_response :success
      assert_live(@post)
      assert_not @post.has_tag?(JAIL)
      assert @post.has_tag?("gore"), "a release leaves the banished tag where it is"

      # an unrelated edit later does not re-jail it either
      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore sky" }}
      assert_live(@post)
      assert_equal 1, deletion_flags(@post).count
    end

    # A RELEASE IS FINAL AGAINST THE AUTOMATIC PASS (review, 2026-09-24).
    # fourier-sampling's jailPolicy keeps the md5s a human released as
    # `exempt`: "never auto-jailed again, whatever the rules say", because
    # otherwise the next automatic run silently re-jails what a human just
    # decided to keep. This jail is an automatic pass too, and the retag
    # timer pushes hydra's tags onto released posts without consulting that
    # list -- so a released post that gained a SECOND banished name from it
    # was jailed again here, undoing the human's decision where sampling
    # never would. A human can still jail it again by hand (the pill).
    should "stay released when the retag bot adds a different banished tag" do
      post_auth fourier_jail_release_path, @bot, params: { md5: @post.md5 }
      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore" }}
      assert_live(@post)

      # fourier-sampling's BooruClient#addTags, paired, over Basic auth
      put post_path(@post, format: :json), as: :json, headers: basic_auth(@bot), params: { post: { tag_string: "landscape gore feces", old_tag_string: "landscape gore" }}

      assert_response :success
      assert_live(@post)
      assert @post.has_tag?("feces")
      assert_not @post.has_tag?(JAIL)
      assert_equal 1, deletion_flags(@post).count
    end

    should "stay released when the banished tag is taken off and then put back" do
      post_auth fourier_jail_release_path, @bot, params: { md5: @post.md5 }
      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape" }}
      assert_live(@post)

      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore" }}

      assert_live(@post)
      assert_equal 1, deletion_flags(@post).count
    end

    should "stay released when an admin unjails and undeletes it from the post page pill" do
      admin = create(:admin_user)

      patch_json = ->(params) { patch modulation_moderation_path(@post), params: params, as: :json }
      login_as(admin)
      patch_json.call({ jail: false })
      assert_response :success
      patch_json.call({ deleted: false })
      assert_response :success

      assert_live(@post)
      assert_not @post.has_tag?(JAIL)
      assert @post.has_tag?("gore")

      # and, released by a human, it is not jailed again by a later gain
      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore scat" }}
      assert_live(@post)
    end
  end

  # The exemption is for a RELEASE, not for any post that was ever deleted:
  # an ordinary deletion a moderator reversed is no human verdict on a
  # banished tag, and a banished tag it gains afterwards still jails it.
  context "A post undeleted after an ordinary deletion" do
    should "still be jailed when it gains a banished tag" do
      member = create(:user)
      post = as(member) { create(:post, tag_string: "landscape", uploader: member) }
      as(create(:admin_user)) { post.delete!("duplicate") }
      post.reload.update_columns(is_deleted: false)

      put_auth post_path(post, format: :json), member, as: :json, params: { post: { tag_string: "landscape gore" }}

      assert_jailed(post, "gore")
    end
  end
end
