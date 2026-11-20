# frozen_string_literal: true

require "test_helper"

# boo.122 D4 (2026-11-20): an upload is a record of a post's file and where
# it came from -- its source, its referer, each file's page and URL. Upload
# and UploadMediaAsset reach their posts through media assets' md5s, not a
# belongs_to :post, so ApplicationRecord's hidden-post rule was a no-op for
# both: every moderator and admin was shown the source of a jailed post on
# /uploads, /uploads/:id, /uploads/:id/assets, a source search and
# /user_actions, though the post itself answers them 404.
#
# Now an upload holding a post hidden from the viewer (Post.hidden_from) is
# hidden with it, except from its own uploader, who chose the source and
# holds the file (hidden_duplicate_upload_test). An admin therefore no longer
# sees a jailed post's upload: the jail hides the post from admins too.
#
# A viewer who may not see the upload at all (a member, not its uploader)
# gets the same answer for a jailed upload as for any other, so the status
# says nothing about which uploads hold hidden posts.
class UploadSourceHiddenTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  JAILED_SOURCE = "https://example.com/d4-jailed-source.jpg"
  LIVE_SOURCE = "https://example.com/d4-live-source.jpg"
  DELETED_SOURCE = "https://example.com/d4-deleted-source.jpg"

  # A completed upload of `post`'s file by `user` from `source`.
  def upload_of(post, user, source)
    upload = build(:upload, uploader: user, media_asset_count: 1, status: "completed", source: source, referer_url: source)
    create(:upload_media_asset, upload: upload, media_asset: post.media_asset, status: "active", source_url: source, page_url: source)
  end

  def ids_at(path, user, **params)
    get_auth path, user, params: params
    assert_response :success, "#{path}: #{response.body}"
    response.parsed_body.pluck("id")
  end

  context "An upload of a jailed post" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!

      @admin = create(:admin_user)
      @moderator = create(:moderator_user)
      @member = create(:user)
      @sample = create(:approver_user, name: "sample")
      @uploader = create(:contributor_user) # posts several fixtures: no upload limit

      # Real files (post_with_file): MediaAsset#trash! deletes them, and a
      # factory asset with none fails the delete for a reason of its own.
      @jailed = as(@uploader) { create(:post_with_file, filename: "png/test.png", uploader: @uploader, tag_string: "landscape") }
      as(@sample) { @jailed.update!(tag_string: "landscape #{JAIL}") }
      @jailed.reload.delete!("troll jail: shock", user: @sample)
      @jailed.reload

      @live = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @deleted = as(@uploader) { create(:post_with_file, uploader: @uploader, tag_string: "landscape") }
      @deleted.delete!("duplicate", user: @admin)
      @deleted.reload

      @jailed_asset = upload_of(@jailed, @uploader, JAILED_SOURCE)
      @jailed_upload = @jailed_asset.upload
      @live_asset = upload_of(@live, @uploader, LIVE_SOURCE)
      @live_upload = @live_asset.upload
      @deleted_upload = upload_of(@deleted, @uploader, DELETED_SOURCE).upload

      assert @jailed.jailed?, "fixture: the post is jailed"
      [@moderator, @admin].each do |viewer|
        assert Post.hidden_from(viewer).exists?(@jailed.id), "fixture: the jailed post is hidden from #{viewer.level_string}"
        assert_not Post.hidden_from(viewer).exists?(@live.id), "fixture: the live post is not"
      end
      assert_not @deleted.hidden_from?(@admin), "fixture: an admin sees an ordinary deletion"
    end

    [:moderator, :admin].each do |role|
      context "seen by an #{role} who did not upload it" do
        setup { @viewer = instance_variable_get(:"@#{role}") }

        should "not be listed, by upload or by file" do
          ids = ids_at(uploads_path(format: :json), @viewer, limit: 100)
          assert_includes ids, @live_upload.id, "control"
          assert_not_includes ids, @jailed_upload.id

          ids = ids_at(upload_media_assets_path(format: :json), @viewer, limit: 100)
          assert_includes ids, @live_asset.id, "control"
          assert_not_includes ids, @jailed_asset.id
        end

        should "not be found by its source" do
          assert_equal [@live_upload.id], ids_at(uploads_path(format: :json), @viewer, search: { any_source_matches: LIVE_SOURCE }), "control"
          assert_empty ids_at(uploads_path(format: :json), @viewer, search: { any_source_matches: JAILED_SOURCE })
          assert_empty ids_at(upload_media_assets_path(format: :json), @viewer, search: { source_url: JAILED_SOURCE })
        end

        should "answer not found at its own pages" do
          get_auth upload_path(@live_upload, format: :json), @viewer
          assert_response :success, "control"

          get_auth upload_path(@jailed_upload, format: :json), @viewer
          assert_response 404
          get_auth upload_path(@jailed_upload), @viewer
          assert_response 404
          get_auth upload_upload_media_asset_path(@jailed_upload, @jailed_asset, format: :json), @viewer
          assert_response 404
          get_auth upload_upload_media_assets_path(@jailed_upload), @viewer
          assert_response 404
          get_auth upload_upload_media_assets_path(@jailed_upload, format: :json), @viewer
          assert_response 404
          assert_no_match(/d4-jailed-source/, response.body)
        end

        should "not be named in the uploader's actions" do
          get_auth user_actions_path(format: :json), @viewer, params: { search: { user_id: @uploader.id }, limit: 200 }
          assert_response :success
          uploads = response.parsed_body.select { |row| row["model_type"] == "Upload" }.pluck("model_id")
          assert_includes uploads, @live_upload.id, "control"
          assert_not_includes uploads, @jailed_upload.id
        end
      end
    end

    # R1 for the file itself: MediaAsset names its post through the md5, so
    # ApplicationRecord's write rule answered false and an admin's delete
    # trashed a jailed post's file. Refused as a missing asset is.
    should "refuse an admin's delete of its file exactly as a missing file's" do
      asset = @jailed.media_asset
      jailed, missing = [asset.id, 0].map do |id|
        delete_auth media_asset_path(id, format: :json), @admin
        # An admin is shown the backtrace, which names the raise site; the
        # answer is the rest. A delete that went through answers 204, empty.
        body = response.parsed_body
        [response.status, body.is_a?(Hash) ? body.except("backtrace") : body]
      end

      assert_equal 404, jailed.first
      assert_equal missing, jailed
      assert_equal "active", asset.reload.status

      get_auth media_asset_path(asset, format: :json), @admin
      assert_response 404, "and the read, which the central rule already refused"
    end

    should "still let an admin delete the file of an ordinary deleted post" do
      delete_auth media_asset_path(@deleted.media_asset, format: :json), @admin
      assert_response :success
      assert_equal "deleted", @deleted.media_asset.reload.status
    end

    should "still show an admin the upload of an ordinary deleted post" do
      assert_includes ids_at(uploads_path(format: :json), @admin, limit: 100), @deleted_upload.id
      get_auth upload_path(@deleted_upload, format: :json), @admin
      assert_response :success
    end

    should "stay with its own uploader" do
      ids = ids_at(uploads_path(format: :json), @uploader, limit: 100)
      assert_includes ids, @jailed_upload.id
      assert_includes ids_at(upload_media_assets_path(format: :json), @uploader, limit: 100), @jailed_asset.id

      get_auth upload_path(@jailed_upload, format: :json), @uploader
      assert_response :success
      get_auth upload_upload_media_assets_path(@jailed_upload), @uploader
      assert_response :success
    end

    should "answer a member who did not upload it as any other upload is answered" do
      get_auth upload_path(@live_upload, format: :json), @member
      live_status = response.status
      get_auth upload_path(@jailed_upload, format: :json), @member
      assert_equal live_status, response.status
      assert_equal 403, live_status

      get_auth upload_upload_media_assets_path(@live_upload, format: :json), @member
      assert_response :success
      assert_empty response.parsed_body
      get_auth upload_upload_media_assets_path(@jailed_upload, format: :json), @member
      assert_response :success
      assert_empty response.parsed_body
    end

    should "answer a signed-out visitor as any other upload is answered" do
      get upload_path(@live_upload, format: :json)
      live_status = response.status
      get upload_path(@jailed_upload, format: :json)
      assert_equal live_status, response.status
      assert_not_equal 200, live_status

      get upload_upload_media_assets_path(@jailed_upload, format: :json)
      jailed_status = response.status
      get upload_upload_media_assets_path(@live_upload, format: :json)
      assert_equal response.status, jailed_status
    end
  end
end
