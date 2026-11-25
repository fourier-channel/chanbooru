# frozen_string_literal: true

require "test_helper"

# Who may make this site fetch an address (SourceFetch): the posting bots. The
# switch is posting_restricted_to_bots?, off under test; this file stubs it on.
#
# No request leaves: HTTP::Client#perform, the call every request ends in, is
# replaced and records what would have been sent, or the site is a server on
# this machine (LocalSiteHelper). Each door is also asked with the switch off,
# where a member's request IS sent: a refusal at a door that would have sent
# nothing proves nothing.
class SourceFetchTest < ActionDispatch::IntegrationTest
  include LocalSiteHelper
  include IqdbTestHelper

  # No extractor knows this host. Its path has the shape of a page some sites
  # share, so Source::Extractor::Null asks the host which site it is.
  URL = "https://chosen.example.com/notes/995ig09wop"
  # The page an image is said to come from is asked too, at a host of the caller's choosing.
  IMAGE = "https://files.example.com/webpublic-dcab49b3-4ad3-4455-aea0-28aa81ecca48.webp"
  REFERER = "https://chosen.example.com/notes/995ig09wop"
  # A shortener names nothing but where to go, so its extractor must ask it.
  SHORT = "https://bit.ly/abc"

  # Every door a caller can name an address at, as [verb, path, params].
  DOORS = {
    "the source page" => [:get, "/source", { url: URL }],
    "the source api" => [:get, "/source.json", { url: URL }],
    "the source api as xml" => [:get, "/source.xml", { url: URL }],
    "the source api by referer" => [:get, "/source.json", { url: IMAGE, ref: REFERER }],
    "image search" => [:get, "/iqdb_queries", { url: URL }],
    "image search by post" => [:post, "/iqdb_queries.json", { search: { url: URL } }],
    "image search by file url" => [:get, "/iqdb_queries.json", { search: { file_url: URL } }],
    "image search by image url" => [:get, "/iqdb_queries.json", { search: { image_url: URL } }],
    "artist search by url" => [:get, "/artists", { search: { url_matches: URL } }],
    "artist search by name or url" => [:get, "/artists.json", { search: { any_name_or_url_matches: URL } }],
    "artist search by several urls" => [:get, "/artists.json", { search: { url_matches: "xyz #{URL}" } }],
    "artist url search" => [:get, "/artist_urls.json", { search: { url_matches: URL } }],
    "artist search from artist urls" => [:get, "/artist_urls.json", { search: { artist: { url_matches: URL } } }],
    "artist search from tags" => [:get, "/tags.json", { search: { artist: { url_matches: URL } } }],
    "artist search from wiki pages" => [:get, "/wiki_pages.json", { search: { artist: { url_matches: URL } } }],
    "a new artist from a source" => [:get, "/artists/new", { artist: { source: URL } }],
  }

  # Records every request that would have left, as "VERB host", and answers it.
  def stub_network!
    sent = @sent = []
    answer = HTTP::Response.new(status: 200, version: "1.1", body: +"", request: HTTP::Request.new(verb: :get, uri: URL))
    HTTP::Client.any_instance.stubs(:perform).with do |request, _options|
      sent << "#{request.verb} #{request.uri.host}"
      true
    end.returns(answer)
  end

  def restrict!
    Danbooru.config.stubs(:posting_restricted_to_bots?).returns(true)
    Danbooru.config.stubs(:fourier_posting_bot_names).returns(%w[sample tunnel])
  end

  def ask(door, user)
    verb, path, params = DOORS.fetch(door)
    if user.nil?
      send(verb, path, params:)
    else
      send("#{verb}_auth", path, user, params:)
    end
  end

  def assert_fetch_refused
    assert_response 403
    assert_match(/does not fetch web addresses/, response.body)
    assert_match(%r{/iqdb_queries}, response.body)
    assert_match(/fourier_posting_bot_names/, response.body)
  end

  # An image on a site of somebody's choosing, which is this machine.
  def chosen_site
    @chosen_site ||= public_site("media.example.com") do
      [200, { "Content-Type" => "image/jpeg" }, File.binread(Rails.root.join("test/files/jpg/test.jpg"))]
    end
  end

  setup do
    RateLimit.delete_all
    @member = create(:user, created_at: 1.month.ago)
    @moderator = create(:moderator_user, created_at: 1.month.ago)
    @admin = create(:admin_user, created_at: 1.month.ago)
    @sample = create(:approver_user, name: "sample", created_at: 1.month.ago)
  end

  context "With fetches for everyone (the control):" do
    DOORS.each_key do |door|
      should "#{door} sends a member's request" do
        stub_network!
        ask(door, @member)
        assert_equal(["get chosen.example.com"], @sent.uniq)
      end
    end

    should "image search downloads the file at the address" do
      mock_iqdb_matches([])
      get_auth iqdb_queries_path(format: :json), @member, params: { url: chosen_site.url("a.jpg") }
      assert_response :success
      assert_equal(1, chosen_site.requests.size)
    end

    should "the artist form opened with a name fetches the source of a post" do
      stub_network!
      as(@member) { create(:post, tag_string: "some_artist", source: URL) }
      get_auth new_artist_path, @member, params: { artist: { name: "some_artist" } }
      assert_equal(["get chosen.example.com"], @sent.uniq)
    end
  end

  context "With fetches for the posting bots only:" do
    setup { restrict! }

    DOORS.each_key do |door|
      should "#{door} refuses a member, with the remedy" do
        stub_network!
        Resolv.expects(:getaddress).never
        ask(door, @member)
        assert_equal([], @sent)
        assert_fetch_refused
      end

      should "#{door} refuses an admin too" do
        stub_network!
        ask(door, @admin)
        assert_equal([], @sent)
        assert_fetch_refused
      end

      should "#{door} sends nothing for a visitor" do
        stub_network!
        ask(door, nil)
        assert_equal([], @sent)
        assert_not_equal(200, response.status)
      end
    end

    should "image search does not look the address up or ask it" do
      mock_iqdb_matches([])
      site = chosen_site
      Resolv.unstub(:getaddress)
      Resolv.expects(:getaddress).never
      get_auth iqdb_queries_path(format: :json), @member, params: { url: site.url("a.jpg") }
      assert_fetch_refused
      assert_equal([], site.requests)
    end

    should "refuse everyone when no bot is named, and say so" do
      stub_network!
      Danbooru.config.stubs(:fourier_posting_bot_names).returns([])
      ask("the source api", @sample)
      assert_fetch_refused
      assert_match(/is empty/, response.body)
      assert_equal([], @sent)
    end

    should "send a bot's request" do
      stub_network!
      ask("the source api", @sample)
      assert_response :success
      assert_equal(["get chosen.example.com"], @sent.uniq)
    end

    should "not refuse a search that sends nothing" do
      artist = as(@member) { create(:artist, url_string: "https://www.pixiv.net/users/1234") }
      stub_network!

      get_auth artists_path(format: :json), @member, params: { search: { any_name_or_url_matches: artist.name } }
      assert_response :success
      assert_equal([artist.id], response.parsed_body.pluck("id"))

      get_auth artist_urls_path(format: :json), @member, params: { search: { url_matches: "*pixiv.net*" } }
      assert_response :success
      assert_equal([artist.id], response.parsed_body.pluck("artist_id"))

      get_auth artist_urls_path(format: :json), @member, params: { search: { url_matches: "https://www.pixiv.net/users/1234" } }
      assert_response :success
      assert_equal([artist.id], response.parsed_body.pluck("artist_id"))

      assert_equal([], @sent)
    end

    should "leave image search by file, post and hash alone" do
      found = as(@member) { create(:post_with_file, filename: "jpg/test.jpg") }
      file = -> { Rack::Test::UploadedFile.new(Rails.root.join("test/files/jpg/test.jpg")) }
      [{ file: file.call }, { post_id: found.id }, { hash: "iqdb_#{"a" * 544}" }].each do |search|
        mock_iqdb_matches([{ post_id: found.id, score: 95.0 }])
        post_auth iqdb_queries_path(format: :json), @member, params: { search: }
        assert_response 201, search.keys.inspect
        assert_equal([found.id], response.parsed_body.pluck("post_id"), search.keys.inspect)
      end
    end

    should "open the artist form with only a name, without fetching" do
      stub_network!
      as(@member) { create(:post, tag_string: "some_artist", source: URL) }
      get_auth new_artist_path, @member, params: { artist: { name: "some_artist" } }
      assert_response :success
      assert_select "input#artist_name[value=some_artist]"
      assert_equal([], @sent)
    end

    should "refuse a member and a moderator an upload or a replacement by address" do
      stub_network!
      target = create(:post)
      perform_enqueued_jobs do
        get_auth new_upload_path, @member, params: { url: URL }
        assert_response 403
        post_auth uploads_path(format: :json), @member, params: { upload: { source: URL } }
        assert_response 403
        post_auth post_replacements_path(post_id: target.id, format: :json), @moderator, params: { post_replacement: { replacement_url: URL } }
        assert_response 403
      end
      assert_equal([], @sent)
    end

    should "refuse in the job when the uploader is not a bot, and say why in the upload" do
      upload = nil
      perform_enqueued_jobs { upload = create(:upload, uploader: @member, source: chosen_site.url("a.jpg")) }
      assert_equal("error", upload.reload.status)
      assert_match(/does not fetch web addresses/, upload.error)
      assert_equal([], chosen_site.requests)
    end

    should "fetch what a bot uploads by address" do
      perform_enqueued_jobs do
        post_auth uploads_path(format: :json), @sample, params: { upload: { source: chosen_site.url("a.jpg") } }
      end
      assert_response 201
      upload = Upload.last
      assert_equal("completed", upload.reload.status, upload.error)
      assert_equal(1, chosen_site.requests.size)
    end

    should "show a bot's upload by address to a moderator without fetching, and fetch for the bot" do
      upload = build(:upload, uploader: @sample, source: URL, media_asset_count: 1, status: "completed")
      upload.upload_media_assets = [build(:upload_media_asset, upload: nil, source_url: URL, page_url: nil, status: "active", media_asset: build(:media_asset))]
      upload.save!
      asset = upload.upload_media_assets.first

      stub_network!
      get_auth upload_path(upload), @moderator
      assert_response :success
      get_auth upload_upload_media_assets_path(upload), @moderator
      assert_response :success
      get_auth upload_media_asset_path(asset), @moderator
      assert_response :success
      assert_equal([], @sent)

      get_auth upload_path(upload), @sample
      assert_response :success
      assert_equal(["get chosen.example.com"], @sent.uniq)
    end

    should "offer a fetch only to those it is made for" do
      shown = as(@member) { create(:post, uploader: @sample, source: URL) }
      stub_network!

      get_auth iqdb_queries_path, @member
      assert_select "input[name='search[url]']", count: 0
      assert_select "input[name='search[post_id]']", count: 1
      get_auth iqdb_queries_path, @sample
      assert_select "input[name='search[url]']", count: 1

      get_auth post_path(shown), @member
      assert_response :success
      assert_select ".source-data", count: 0
      assert_select "#commentary_source_type option[value=Source]", count: 0
      assert_select "#commentary_source_type option[value=Post]", count: 1
      get_auth post_path(shown), @sample
      assert_select ".source-data", count: 1
      assert_select "#commentary_source_type option[value=Source]", count: 1
    end
  end

  context "Every extractor:" do
    # The chokepoint is a client, so it holds only if no extractor builds its own.
    should "send with a client that asks who it is for" do
      Rails.application.eager_load!
      extractors = Source::Extractor.descendants
      assert_operator(extractors.size, :>, 80)

      restrict!
      stub_network!
      CurrentUser.scoped(@member) do
        extractors.each do |klass|
          # An extractor may ask its own kind of URL which headers to send.
          url = Source::URL.url_subclasses.find { |kind| kind.extractors.include?(klass) } || Source::URL::Null
          extractor = klass.new(url.new("https://example.com/"))
          %i[http http_downloader].each do |client|
            built = begin
              extractor.send(client)
            rescue SourceFetch::RefusedError
              next # It asks the site for a token first, with a client that asked.
            end
            assert(built.http.default_options.features.key?(:requested_by), "#{klass}##{client} does not ask who it is for")
          end
        end
      end
      assert_equal([], @sent)
    end

    should "have no other client to send with" do
      built = %w[app/logical/source app/logical/twitter_transaction_id_generator.rb].flat_map do |path|
        root = Rails.root.join(path)
        (root.directory? ? root.glob("**/*.rb") : [root]).flat_map do |file|
          code = file.readlines.reject { |line| line.strip.start_with?("#") }
          code.grep(/Danbooru::Http\.[a-z]|Net::HTTP|URI\.open|HTTP\.(get|post|head)|TCPSocket|Resolv/).map { |line| "#{file.relative_path_from(Rails.root)}: #{line.strip}" }
        end
      end
      assert_equal(["app/logical/source/extractor.rb: Danbooru::Http.external.use(requested_by: { user: @requester })"], built)
    end

    should "keep the one it was built for, in whichever thread it sends" do
      restrict!
      stub_network!
      extractor = CurrentUser.scoped(@member) { Source::Extractor.find(SHORT) }
      assert_raises(SourceFetch::RefusedError) { CurrentUser.scoped(@sample) { extractor.redirect_url } }
      assert_equal([], @sent)

      extractor = SourceFetch.on_behalf_of(@sample) { Source::Extractor.find(SHORT) }
      Thread.new { extractor.redirect_url }.join
      assert_equal(["head bit.ly"], @sent)
    end

    should "refuse when nobody asked" do
      restrict!
      stub_network!
      extractor = CurrentUser.scoped(nil) { Source::Extractor.find(SHORT) }
      assert_raises(SourceFetch::RefusedError) { extractor.redirect_url }
      assert_raises(SourceFetch::RefusedError) { CurrentUser.scoped(User.system) { Source::Extractor.find(SHORT).redirect_url } }
      assert_equal([], @sent)
    end
  end
end
