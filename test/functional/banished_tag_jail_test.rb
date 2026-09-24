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

  def assert_jailed(post, tag)
    post.reload
    assert post.is_deleted?, "post ##{post.id} should be deleted; tags: #{post.tag_string}"
    assert post.has_tag?(JAIL), "post ##{post.id} should carry #{JAIL}; tags: #{post.tag_string}"
    assert_equal "troll jail: banished tag #{tag}", deletion_flags(post).last&.reason
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

    should "name every banished tag it gained" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape scat gore" }}

      @post.reload
      assert @post.is_deleted?
      assert_equal "troll jail: banished tags gore, scat", deletion_flags(@post).last.reason
    end

    should "tag first and delete second, as the booru's own system user, and log it" do
      put_auth post_path(@post, format: :json), @member, as: :json, params: { post: { tag_string: "landscape gore" }}

      @post.reload
      assert_equal [User.system.id], deletion_flags(@post).pluck(:creator_id)
      action = ModAction.where(subject: @post, category: "post_delete").last
      assert_equal User.system, action.creator
      assert_match(/banished tag gore/, action.description)
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

    should "be jailed again if the banished tag is taken off and then put back" do
      post_auth fourier_jail_release_path, @bot, params: { md5: @post.md5 }
      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape" }}
      assert_live(@post)

      put_auth post_path(@post, format: :json), @bot, as: :json, params: { post: { tag_string: "landscape gore" }}

      assert_jailed(@post, "gore")
      assert_equal 2, deletion_flags(@post).count
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
    end
  end
end
