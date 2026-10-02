# frozen_string_literal: true

require "test_helper"

# Uploading the bytes of a post you may not see neither changes that post nor
# names it (Post#refuses_duplicate_upload_from?).
#
# Found 2026-10-02 from fourier-tunnel's logs plus read-only SQL: the tunnel
# uploaded the files of deleted posts 22, 25 and 164076 (jailed), and
# PostsController#create merged the uploader's tags and rating INTO each
# deleted post and answered 302 to /posts/<id> -- handing the id of a post
# that answers nothing anywhere else to whoever held the bytes. The tunnel had
# uploaded all three itself, which is why the rule is wider than
# Post#hidden_from?: a deleted post's own uploader may READ it (an appeal),
# but may not re-tag it by uploading its file again.
#
# The refusal is a 422 carrying reason "unpostable", no post id and no
# Location, so a client can tell "this file will not be posted" from a
# transient error without being told which post holds it.
#
# The same file asks the other doors that named or changed such a post: the
# upload page and its JSON, the upload galleries, ?only= includes, a post
# replacement, and a write to the post by id.
class HiddenDuplicateUploadTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  REFUSAL = {
    "success" => false,
    "error" => "This file cannot be posted.",
    "message" => "This file cannot be posted.",
    "fix" => "Do not retry: this file will not be posted. Upload a different file.",
    "reason" => "unpostable",
  }.freeze

  # A completed upload of `post`'s file by `user`, and the asset to post it from.
  def upload_of(post, user)
    upload = build(:upload, uploader: user, media_asset_count: 1, status: "completed")
    create(:upload_media_asset, upload: upload, media_asset: post.media_asset, status: "active")
  end

  def create_post_from(asset, user, format: :json, tags: "dup_tag", rating: "e")
    RateLimit.delete_all
    params = { upload_media_asset_id: asset.id, post: { rating: rating, tag_string: tags }}
    user ? post_auth(posts_path(format: format), user, params: params) : post(posts_path(format: format), params: params)
  end

  # The post as it stood, so "unchanged" is asserted field by field.
  def snapshot(post)
    post.reload.slice(:tag_string, :rating, :parent_id, :updated_at)
  end

  def assert_refused(post, before, who)
    assert_response 422, "#{who}: #{response.body}"
    assert_nil response.headers["Location"], who
    assert_equal REFUSAL, response.parsed_body, who
    assert_no_match(/\b#{post.id}\b/, response.body, who)
    assert_equal before, snapshot(post), "#{who}: the hidden post was changed"
  end

  context "With deleted and jailed posts hidden as in production" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_need_reveal?).returns(true)

      @bot = create(:builder_user)         # the scraper: uploads 4chan threads
      @tunnel = create(:contributor_user)  # the Matrix bridge, level 35 like production's
      @member = create(:user)
      @approver = create(:approver_user)   # the jailing account's tier
      @admin = create(:admin_user)
      @admin_off = create(:admin_user)
      ModulationSetting.record!(@admin, nil, { "reveal_banished" => "true" })

      as(@bot) do
        @jailed = create(:post, tag_string: "landscape hidden_marker #{JAIL}", uploader: @bot, rating: "q")
        @deleted = create(:post, tag_string: "landscape deleted_marker", uploader: @bot, rating: "q")
        @visible = create(:post, tag_string: "landscape", uploader: @bot, rating: "q")
        @child = create(:post, tag_string: "landscape", uploader: @bot, parent_id: @jailed.id)
      end
      # The observed shape: the tunnel's OWN post, deleted.
      as(@tunnel) { @own_deleted = create(:post, tag_string: "landscape own_marker", uploader: @tunnel, rating: "q") }

      @jailed.delete!("troll jail: shock", user: @admin)
      @deleted.delete!("ordinary deletion", user: @admin)
      @own_deleted.delete!("ordinary deletion", user: @admin)
      [@jailed, @deleted, @own_deleted, @child].each(&:reload)

      assert @jailed.is_deleted? && @jailed.has_tag?(JAIL), "fixture: jailed"
      assert_equal @jailed.id, @child.parent_id, "fixture: the visible child names the jailed parent"
    end

    context "creating a post from the file of a hidden post" do
      should "refuse a member, change nothing, and name no post" do
        [@jailed, @deleted].each do |hidden|
          before = snapshot(hidden)
          assert_no_difference("Post.count") { create_post_from(upload_of(hidden, @member), @member) }
          assert_refused(hidden, before, "member, post ##{hidden.id}")
        end
      end

      should "refuse a member's HTML form the same way, with no redirect and no notice naming it" do
        before = snapshot(@jailed)
        create_post_from(upload_of(@jailed, @member), @member, format: :html)

        assert_response 422
        assert_nil response.headers["Location"]
        assert_includes response.body, "This file cannot be posted."
        assert_no_match(%r{/posts/#{@jailed.id}\b|post ##{@jailed.id}\b|Duplicate of}, response.body)
        assert_equal before, snapshot(@jailed)
      end

      should "refuse the tunnel for someone else's jailed post" do
        before = snapshot(@jailed)
        create_post_from(upload_of(@jailed, @tunnel), @tunnel, tags: "41chan_someone dup_tag")
        assert_refused(@jailed, before, "tunnel, jailed")
      end

      # Posts 22 and 25 on 2026-10-02: uploaded by the tunnel, deleted, and
      # uploaded again by the tunnel.
      should "refuse the tunnel for its OWN deleted post, which it may still read" do
        assert_not @own_deleted.hidden_from?(@tunnel), "fixture: the uploader can read its deleted post"
        before = snapshot(@own_deleted)
        create_post_from(upload_of(@own_deleted, @tunnel), @tunnel)
        assert_refused(@own_deleted, before, "tunnel, own deleted")
      end

      should "refuse an approver, who cannot see deleted posts either" do
        before = snapshot(@deleted)
        create_post_from(upload_of(@deleted, @approver), @approver)
        assert_refused(@deleted, before, "approver, deleted")
      end

      should "refuse an admin with reveal off for a jailed post" do
        before = snapshot(@jailed)
        create_post_from(upload_of(@jailed, @admin_off), @admin_off)
        assert_refused(@jailed, before, "admin, reveal off")
      end

      should "still merge and redirect for an admin who can see the post" do
        create_post_from(upload_of(@jailed, @admin), @admin)
        assert_redirected_to post_path(@jailed)
        assert_includes @jailed.reload.tag_array, "dup_tag"

        create_post_from(upload_of(@deleted, @admin_off), @admin_off, tags: "admin_tag")
        assert_redirected_to post_path(@deleted)
        assert_includes @deleted.reload.tag_array, "admin_tag"
      end

      should "still merge and redirect for anyone uploading a visible post's file" do
        [@member, @tunnel].each do |user|
          create_post_from(upload_of(@visible, user), user, tags: "seen_by_#{user.id}")
          assert_redirected_to post_path(@visible)
          assert_includes @visible.reload.tag_array, "seen_by_#{user.id}"
        end
      end

      # Anonymous cannot create a post at all (PostPolicy#create?), before
      # this change or after. Asserted so a later change to that cannot open
      # this door without a red here.
      should "give a signed-out visitor nothing that names the post" do
        asset = upload_of(@jailed, @member)
        before = snapshot(@jailed)
        create_post_from(asset, nil)

        assert_includes [403, 404, 422], response.status
        assert_nil response.headers["Location"]
        assert_no_match(/\b#{@jailed.id}\b/, response.body)
        assert_equal before, snapshot(@jailed)
      end
    end

    context "the upload's own pages" do
      setup do
        @asset = upload_of(@jailed, @member)
        @upload = @asset.upload
      end

      should "not serialize the hidden post inside the upload" do
        get_auth upload_path(@upload, format: :json), @member
        assert_response :success
        media_asset = response.parsed_body.dig("upload_media_assets", 0, "media_asset")
        assert_not_nil media_asset, response.body
        assert_not media_asset.key?("post"), response.body

        get_auth uploads_path(format: :json), @member, params: { only: "id,posts,media_assets[id,post]" }
        assert_response :success
        row = response.parsed_body.find { |u| u["id"] == @upload.id }
        assert_empty row["posts"], response.body
        assert row["media_assets"].none? { |m| m.key?("post") }, response.body
      end

      should "not redirect to the hidden post or link it from the galleries" do
        get_auth upload_path(@upload), @member
        assert_response :success
        assert_no_match(%r{/posts/#{@jailed.id}\b|post ##{@jailed.id}\b}, response.body)

        get_auth upload_upload_media_asset_path(@upload, @asset), @member
        assert_response :success
        assert_no_match(%r{/posts/#{@jailed.id}\b|post ##{@jailed.id}\b}, response.body)

        get_auth uploads_path, @member, params: { search: { status: "completed" }}
        assert_response :success
        assert_no_match(%r{post ##{@jailed.id}\b}, response.body)

        get_auth upload_media_assets_path, @member, params: { upload_id: @upload.id }
        assert_response :success
        assert_no_match(%r{post ##{@jailed.id}\b}, response.body)
      end

      should "still redirect an admin with reveal on to the post" do
        asset = upload_of(@jailed, @admin)
        get_auth upload_path(asset.upload), @admin
        assert_redirected_to @jailed
      end
    end

    context "a visible post's nested posts" do
      should "leave out a hidden parent, signed out and as a member" do
        [nil, @member].each do |user|
          user ? get_auth(post_path(@child, format: :json), user, params: { only: "id,parent_id,parent" }) : get(post_path(@child, format: :json), params: { only: "id,parent_id,parent" })
          assert_response :success
          assert_not response.parsed_body.key?("parent"), "#{user&.name || "anonymous"}: #{response.body}"
        end
      end

      should "still include it for an admin with reveal on" do
        get_auth post_path(@child, format: :json), @admin, params: { only: "id,parent" }
        assert_response :success
        assert_equal @jailed.id, response.parsed_body.dig("parent", "id")
      end
    end

    context "writing to a hidden post by id" do
      # Before: a member got 200 and changed an ungated deleted post (and its
      # JSON back), and 403 -- not the 404 a missing post gets -- for a gated
      # one; the tunnel (gold and up) got 200 for both.
      should "answer a member and the tunnel 404 and change nothing" do
        [@member, @tunnel].product([@deleted, @jailed]).each do |user, hidden|
          before = snapshot(hidden)
          put_auth post_path(hidden, format: :json), user, params: { post: { tag_string: "#{hidden.tag_string} -#{JAIL} written" }}
          assert_response 404, "#{user.name}, post ##{hidden.id}"
          assert_no_match(/hidden_marker|deleted_marker/, response.body)
          assert_equal before, snapshot(hidden)
        end
      end

      should "still let the moderation tier act on it" do
        put_auth post_path(@jailed, format: :json), @approver, params: { post: { tag_string: "#{@jailed.tag_string} approver_tag" }}
        assert_response :success
        assert_includes @jailed.reload.tag_array, "approver_tag"
      end

      should "still let the uploader write to its own deleted post" do
        put_auth post_path(@own_deleted, format: :json), @tunnel, params: { post: { tag_string: "#{@own_deleted.tag_string} own_tag" }}
        assert_response :success
        assert_includes @own_deleted.reload.tag_array, "own_tag"
      end
    end

    context "replacing a post with a hidden post's file" do
      should "not name the hidden post" do
        # A fresh account: the setup's bot is at its pending-upload limit.
        owner = create(:contributor_user)
        hidden = as(owner) { create(:post, md5: "ecef68c44edb8a0d6a3070b5f8e8ee76", file_size: 1234, uploader: owner) }
        hidden.delete!("ordinary deletion", user: @admin)
        target = as(owner) { create(:post, file_size: 789, uploader: owner) }

        post_auth post_replacements_path, create(:moderator_user), params: {
          post_id: target.id,
          post_replacement: { replacement_file: Rack::Test::UploadedFile.new("test/files/jpg/test.jpg") },
        }

        assert_redirected_to target
        assert_equal "This file cannot be posted.", flash[:notice]
      end
    end
  end
end
