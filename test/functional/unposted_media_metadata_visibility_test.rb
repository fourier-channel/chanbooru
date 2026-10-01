# frozen_string_literal: true

require "test_helper"

# The ExifTool metadata of an unposted asset is as private as the asset (fork
# rule, 2026-10-01; Danbooru.config.unposted_media_assets_restricted?, off
# under test and stubbed on here).
#
# fourier-tunnel gives every Matrix image an unposted asset so the booru
# renders its thumbnails -- DM pictures and avatars included. Upstream lists
# every asset's metadata at /media_metadata.json to anyone, and reaches it
# through ?only= includes from uploads, which moderators can list: a phone
# photo sent in a DM would publish its camera, its timestamps and its GPS.
class UnpostedMediaMetadataVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    Danbooru.config.stubs(:unposted_media_assets_restricted?).returns(true)
    @uploader = create(:builder_user)
    @upload = create(:completed_source_upload, uploader: @uploader)
    @asset = @upload.media_assets.first
    @stranger = create(:user)
    @moderator = create(:moderator_user)
    @admin = create(:admin_user)
  end

  def listed(user)
    path = media_metadata_path(format: :json, search: { media_asset_id: @asset.id })
    user ? get_auth(path, user) : get(path)
    assert_response :success
    response.parsed_body
  end

  def included_through_upload(user)
    get_auth upload_path(@upload, format: :json, only: "id,media_assets[id,media_metadata]"), user
    assert_response :success
    response.parsed_body.dig("media_assets", 0, "media_metadata", "metadata")
  end

  should "carry real metadata to start with" do
    assert @asset.media_metadata.metadata.to_h.present?, "precondition: the factory's asset has ExifTool metadata"
  end

  should "not list an unposted asset's metadata to anonymous visitors, members or moderators" do
    [nil, @stranger, @moderator].each do |viewer|
      assert_empty listed(viewer), "#{viewer&.name || "anonymous"} was listed the metadata"
    end
  end

  should "not hand it to a moderator through an include from the upload" do
    assert_equal({}, included_through_upload(@moderator))
  end

  should "show it to the uploader and to an admin" do
    assert_equal [@asset.id], listed(@uploader).pluck("media_asset_id")
    assert_equal [@asset.id], listed(@admin).pluck("media_asset_id")
    assert included_through_upload(@uploader).present?
  end

  should "leave a posted asset's metadata as upstream has it" do
    as(@uploader) { create(:post, md5: @asset.md5, uploader: @uploader) }
    assert_equal [@asset.id], listed(nil).pluck("media_asset_id")
  end

  context "with the rule off, as under the inherited suite" do
    setup { Danbooru.config.stubs(:unposted_media_assets_restricted?).returns(false) }

    should "behave as upstream: an unposted asset's metadata is listed" do
      assert_equal [@asset.id], listed(@stranger).pluck("media_asset_id")
    end
  end
end
