# frozen_string_literal: true

require "test_helper"

# A media asset with no post is visible only to an admin and to the account
# that uploaded it (fork rule, 2026-09-30; Danbooru.config.
# unposted_media_assets_restricted?, off under test and stubbed on here).
#
# fourier-sampling uploads every image before the taggers and the troll jail
# judge it, so the booru holds an unposted asset for every image waiting to be
# posted AND for every image the jail will never post. Upstream showed such an
# asset to anyone, md5 and variant URLs included, and the media gate serves
# bytes by md5 to anyone: a jailed image was one anonymous request away.
class UnpostedMediaAssetVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    Danbooru.config.stubs(:unposted_media_assets_restricted?).returns(true)
    @uploader = create(:builder_user)
    @upload = create(:completed_source_upload, uploader: @uploader)
    @asset = @upload.media_assets.first
    @stranger = create(:user)
    @moderator = create(:moderator_user)
    @admin = create(:admin_user)
  end

  def shown_md5(user)
    if user
      get_auth media_asset_path(@asset, format: :json), user
    else
      get media_asset_path(@asset, format: :json)
    end
    assert_response :success
    response.parsed_body["md5"]
  end

  def listed_md5s(user)
    if user
      get_auth media_assets_path(format: :json), user
    else
      get media_assets_path(format: :json)
    end
    assert_response :success
    response.parsed_body.map { |a| a["md5"] }
  end

  should "hide an unposted asset's md5 and variants from anonymous visitors and members" do
    [nil, @stranger, @moderator].each do |viewer|
      assert_nil shown_md5(viewer), "#{viewer&.name || "anonymous"} saw the md5"
      assert_not_includes listed_md5s(viewer), @asset.md5
      assert_nil response.parsed_body.find { |a| a["id"] == @asset.id }&.dig("variants")
    end
  end

  should "refuse the image route for an unposted asset" do
    get media_asset_image_path(@asset, "original")
    assert_response 403
    get_auth media_asset_image_path(@asset, "180x180"), @stranger
    assert_response 403
  end

  should "show an unposted asset to its uploader and to an admin" do
    assert_equal @asset.md5, shown_md5(@uploader)
    assert_equal @asset.md5, shown_md5(@admin)
  end

  should "leave a posted asset to its post's visibility" do
    as(@uploader) { create(:post, md5: @asset.md5, uploader: @uploader) }
    assert_equal @asset.md5, shown_md5(nil)
    assert_equal @asset.md5, shown_md5(@stranger)
  end

  context "with the rule off, as under the inherited suite" do
    setup { Danbooru.config.stubs(:unposted_media_assets_restricted?).returns(false) }

    should "behave as upstream: an unposted asset is visible" do
      assert_equal @asset.md5, shown_md5(@stranger)
    end
  end
end
