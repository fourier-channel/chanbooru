require "test_helper"

class UploadTest < ActiveSupport::TestCase
  def assert_tag_match(uploads, query)
    assert_equal(uploads.map(&:id), Upload.ai_tags_match(query).order(id: :desc).pluck("id"))
  end

  context "Upload" do
    context "listing its files" do
      # Unordered, Postgres returns rows in storage order, and an UPDATE can
      # move a row to the end of it -- but whether one does depends on the
      # page and the plan (an in-page update an index scan never sees moved),
      # so a test that updates a row cannot be relied on to reorder them.
      # Here the files are stored in the reverse of their id order, so any
      # plan returns them reversed unless the association asks for id order.
      should "list them by id whatever order the table holds them in" do
        upload = create(:upload, media_asset_count: 3)
        # One query: the query cache answers a repeated identical SELECT
        # from memory, so three nextval calls returned one id three times.
        ids = UploadMediaAsset.connection.select_values("SELECT nextval(pg_get_serial_sequence('upload_media_assets', 'id')) FROM generate_series(1, 3)").map(&:to_i).sort
        ids.reverse.each { |id| create(:upload_media_asset, id: id, upload: upload, source_url: "file://a.zip/#{id}.jpg") }

        assert_equal(ids, upload.reload.upload_media_assets.map(&:id))
        assert_equal(ids, Upload.includes(:upload_media_assets).find(upload.id).upload_media_assets.map(&:id))
        assert_equal(ids.first, upload.upload_media_assets.first.id)
      end
    end

    context "searching" do
      setup do
        @asset1 = create(:media_asset, image_width: 720, image_height: 1280, file_size: 1.megabyte, file_ext: "jpg", media_metadata: build(:media_metadata, metadata: { "File:FileType" => "JPEG" }))
        @asset2 = create(:media_asset, image_width: 1920, image_height: 1080, file_size: 2.megabytes, file_ext: "png", duration: 3.0, media_metadata: build(:media_metadata, metadata: { "File:FileType" => "PNG" }))

        @uma1 = build(:upload_media_asset, media_asset: @asset1, status: "active", created_at: Time.zone.now, source_url: "https://example.com/image.jpg")
        @uma2 = build(:upload_media_asset, media_asset: @asset2, status: "active", created_at: Time.zone.parse("2022-01-01"), source_url: "file://image.png")

        @upload1 = create(:upload, created_at: Time.zone.now, upload_media_assets: [@uma1], source: "https://example.com/posts/1")
        @upload2 = create(:upload, created_at: Time.zone.parse("2022-01-01"), upload_media_assets: [@uma2])
      end

      should "return assets for the id: metatag" do
        assert_tag_match([@upload1], "id:#{@upload1.upload_media_assets.sole.id}")
      end

      should "return assets for the md5: metatag" do
        assert_tag_match([@upload1], "md5:#{@asset1.md5}")
      end

      should "return assets for the width: metatag" do
        assert_tag_match([@upload1], "width:#{@asset1.image_width}")
      end

      should "return assets for the height: metatag" do
        assert_tag_match([@upload1], "height:#{@asset1.image_height}")
      end

      should "return assets for the duration: metatag" do
        assert_tag_match([@upload2], "duration:3")
      end

      should "return assets for the mpixels: metatag" do
        assert_tag_match([@upload1], "mpixels:#{(@asset1.image_width * @asset1.image_height) / 1_000_000.0}")
      end

      should "return assets for the ratio: metatag" do
        assert_tag_match([@upload1], "ratio:#{@asset1.image_width.to_f / @asset1.image_height}")
      end

      should "return assets for the filesize: metatag" do
        assert_tag_match([@upload1], "filesize:1mb")
      end

      should "return assets for the filetype: metatag" do
        assert_tag_match([@upload1], "filetype:jpg")
      end

      should "return assets for the date: tag" do
        assert_tag_match([@upload2], "date:2022-01-01")
      end

      should "return assets for the age: tag" do
        assert_tag_match([@upload1], "age:<1minute")
      end

      should "return assets for the status: tag" do
        assert_tag_match([@upload2, @upload1], "status:active")
      end

      should "return assets for the is: tag" do
        assert_tag_match([@upload1], "is:jpg")
        assert_tag_match([@upload2, @upload1], "is:active")
      end

      should "return assets for the exif: tag" do
        assert_tag_match([@upload2, @upload1], "exif:File:FileType")
        assert_tag_match([@upload1], "exif:File:FileType=JPEG")
      end

      should "return search for sources" do
        assert_equal([@upload1], Upload.any_source_matches("https://example.com/image.jpg"))
        assert_equal([@upload1], Upload.any_source_matches("https://example.com/posts/1"))
        assert_equal([@upload2], Upload.any_source_matches("file://image.png"))
      end
    end

    context "during validation" do
      subject { build(:upload) }

      should normalize_attribute(:source).from("https://example.com/foo bar.jpg").to("https://example.com/foo%20bar.jpg")
      should normalize_attribute(:source).from("https://bond-live.com/en/wp-content/uploads/2024/12/Vライバー-アイキャッチ-23.png").to("https://bond-live.com/en/wp-content/uploads/2024/12/Vライバー-アイキャッチ-23.png")

      should_not allow_value("https://example.com/#{"x" * 2000}.jpg").for(:source)
      should_not allow_value("https://example.com/#{"x" * 2000}.jpg").for(:referer_url)
      should_not allow_value("https://<img src=x onerror=alert(1)>").for(:source)
      should_not allow_value('https://a"><svg/onload=alert(1)>').for(:source)
      should allow_value("https://example.com/image.jpg").for(:source)
    end
  end
end
