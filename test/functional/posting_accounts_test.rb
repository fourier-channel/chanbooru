# frozen_string_literal: true

require "test_helper"

# Who may post (operator ruling 2026-10-07): "The upload path is only ever used
# by the bots. Normal users are not intended to be able to post directly." The
# rule is PostingAccounts, read from Danbooru.config.fourier_posting_bot_names
# by every door that makes content from a file or a URL. The switch is off
# under test (the fork restriction pattern); this file stubs it on.
#
# The bots are exercised the way they call the booru: fourier-sampling as
# `sample` with an api key in a Basic Authorization header, fourier-tunnel as
# `tunnel` with login/api_key params, each POST /uploads.json and then POST
# /posts.json with the upload media asset.
class PostingAccountsTest < ActionDispatch::IntegrationTest
  def upload_params
    { upload: { files: { "0" => Rack::Test::UploadedFile.new(Rails.root.join("test/files/jpg/test.jpg")) } } }
  end

  def basic(user, key)
    { "Authorization" => "Basic #{::Base64.strict_encode64("#{user.name}:#{key.key}")}" }
  end

  # A member's own completed upload, made without the door, so that POST
  # /posts is refused for who is asking and not for whose upload it is.
  def own_upload_media_asset(user)
    upload = build(:upload, uploader: user, media_asset_count: 1, status: "completed")
    create(:upload_media_asset, upload: upload, media_asset: build(:media_asset))
  end

  def assert_refused_as_posting
    assert_response 403
    assert_match(/done by its ingest, not by hand/, response.body)
  end

  context "With posting restricted to the bots" do
    setup do
      Danbooru.config.stubs(:posting_restricted_to_bots?).returns(true)
      RateLimit.delete_all
      @member = create(:user, created_at: 1.month.ago)
      @admin = create(:admin_user, created_at: 1.month.ago)
      @moderator = create(:moderator_user, created_at: 1.month.ago)
      @sample = create(:approver_user, name: "sample", created_at: 1.month.ago)
      @tunnel = create(:contributor_user, name: "tunnel", created_at: 1.month.ago)
      @sample_key = create(:api_key, user: @sample)
      @tunnel_key = create(:api_key, user: @tunnel)
    end

    should "refuse a member an upload, json and the form, with the reason" do
      assert_no_difference("Upload.count") do
        post_auth uploads_path(format: :json), @member, params: upload_params
      end
      assert_refused_as_posting
      get_auth new_upload_path, @member
      assert_refused_as_posting
    end

    should "refuse an admin an upload too: it is the bots' alone" do
      assert_no_difference("Upload.count") do
        post_auth uploads_path(format: :json), @admin, params: upload_params
      end
      assert_refused_as_posting
    end

    should "refuse a member a post made from their own upload" do
      asset = own_upload_media_asset(@member)
      assert_no_difference("Post.count") do
        post_auth posts_path(format: :json), @member, params: { upload_media_asset_id: asset.id, post: { rating: "s", tag_string: "tagme" } }
      end
      assert_refused_as_posting
    end

    should "refuse a moderator a replacement file" do
      target = create(:post)
      assert_no_difference("PostReplacement.count") do
        post_auth post_replacements_path(post_id: target.id, format: :json), @moderator, params: { post_replacement: { replacement_url: "https://example.com/x.jpg" } }
      end
      assert_refused_as_posting
    end

    should "let sample post the way fourier-sampling does" do
      perform_enqueued_jobs do
        post uploads_path(format: :json), params: upload_params, headers: basic(@sample, @sample_key)
      end
      assert_response 201
      upload = Upload.last
      assert_equal(@sample, upload.uploader)
      assert_equal("completed", upload.reload.status, upload.error)

      asset = upload.upload_media_assets.first
      assert_difference("Post.count", 1) do
        post posts_path(format: :json), params: { upload_media_asset_id: asset.id, post: { rating: "s", tag_string: "tagme" } }, headers: basic(@sample, @sample_key), as: :json
      end
      assert_response 201
      assert_equal(@sample, Post.last.uploader)
    end

    should "let tunnel post the way fourier-tunnel does" do
      # axios `params`: the credentials ride in the query string.
      auth = { login: @tunnel.name, api_key: @tunnel_key.key }
      perform_enqueued_jobs do
        post uploads_path(format: :json, **auth), params: upload_params
      end
      assert_response 201
      upload = Upload.last
      assert_equal(@tunnel, upload.uploader)
      assert_equal("completed", upload.reload.status, upload.error)

      asset = upload.upload_media_assets.first
      assert_difference("Post.count", 1) do
        post posts_path(format: :json, **auth), params: { upload_media_asset_id: asset.id, post: { rating: "s", tag_string: "tagme" } }, as: :json
      end
      assert_response 201
      assert_equal(@tunnel, Post.last.uploader)
    end

    should "let nobody post when the list is empty, and say which setting is empty" do
      Danbooru.config.stubs(:fourier_posting_bot_names).returns([])
      assert_no_difference("Upload.count") do
        post uploads_path(format: :json), params: upload_params, headers: basic(@sample, @sample_key)
      end
      assert_refused_as_posting
      assert_match(/fourier_posting_bot_names is empty/, response.body)
    end

    should "let nobody post when the list is missing" do
      Danbooru.config.stubs(:fourier_posting_bot_names).returns(nil)
      post uploads_path(format: :json), params: upload_params, headers: basic(@sample, @sample_key)
      assert_refused_as_posting
    end

    should "not offer a member the upload links, and offer them to a bot" do
      get_auth site_map_path, @member
      assert_select "a[href='#{new_upload_path}']", count: 0
      get_auth posts_path, @member
      assert_select "a[href='#{new_upload_path}']", count: 0
      get site_map_path
      assert_select "a[href='#{new_upload_path}']", count: 0

      get_auth site_map_path, @sample
      assert_select "a[href='#{new_upload_path}']", count: 1
    end

    should "leave a member's tag edit alone (Technetium edits tags as a member)" do
      target = create(:post, tag_string: "aaa")
      put_auth post_path(target, format: :json), @member, params: { post: { tag_string: "aaa bbb" } }
      assert_response :success
      assert_equal("aaa bbb", target.reload.tag_string)
    end
  end
end
