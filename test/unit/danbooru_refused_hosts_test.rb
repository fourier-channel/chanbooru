# frozen_string_literal: true

require "test_helper"

# The refusal of hosts this site must never contact (Danbooru::RefusedHosts).
# Stubs only: HTTP::Client#perform, the call every request ends in, is replaced
# for every test here, so nothing in this file can reach the network.
class DanbooruRefusedHostsTest < ActiveSupport::TestCase
  REFUSED = Danbooru::RefusedHosts::HOSTS.first

  # Records every request that would have left, as "VERB host". The first
  # requests are answered with `redirects`, in order, and the rest with a 200.
  def stub_network!(redirects: {})
    sent = @sent = []
    HTTP::Client.any_instance.stubs(:perform).with do |request, _options|
      sent << "#{request.verb} #{request.uri.host}"
      true
    end.returns(*responses(redirects))
  end

  def responses(redirects)
    redirects.map { |from, to| response(302, from, "Location" => to) } + [response(200, "https://example.com/")]
  end

  def response(status, url, headers = {})
    HTTP::Response.new(status:, headers:, version: "1.1", body: "", request: HTTP::Request.new(verb: :get, uri: url))
  end

  def assert_refused(response)
    assert_equal(Danbooru::Http::REFUSED_HOST_STATUS, response.code)
    assert_equal([], @sent.grep(/#{Regexp.escape(REFUSED)}/i))
  end

  context "A request to a refused host:" do
    setup { stub_network! }

    should "never be sent, however the host is spelled" do
      [
        "https://#{REFUSED}/@a/1",
        "http://#{REFUSED}:8080/",
        "https://user:pass@#{REFUSED}/",
        "https://#{REFUSED.upcase}/",
        "https://#{REFUSED}./",
        "https://media.#{REFUSED}/a.png",
        "https://a.b.c.#{REFUSED.capitalize}./a.png",
        "https://#{REFUSED.sub(".", "%2E")}/",
      ].each do |url|
        assert_equal(Danbooru::Http::REFUSED_HOST_STATUS, Danbooru::Http.new.get(url).code, url)
      end
      assert_equal([], @sent)
    end

    should "never be sent by any verb" do
      %i[get head put post delete].each do |verb|
        assert_refused(Danbooru::Http.new.send(verb, "https://#{REFUSED}/"))
      end
      assert_equal([], @sent)
    end

    should "never be sent by any of the clients" do
      [
        Danbooru::Http.new,
        Danbooru::Http.external,
        Danbooru::Http.internal,
        Danbooru::Http.public_only,
        Danbooru::Http.proxy(url: "http://user:pass@proxy.example.com:8080"),
        Danbooru::Http.external.with_legacy_ssl.no_follow.cache(1.minute).use(:spoof_referrer).use(retriable: { max_retries: 2 }),
      ].each do |http|
        assert_refused(http.get("https://media.#{REFUSED}/a.png"))
      end
      assert_equal([], @sent)
    end

    should "never be sent when the configured proxy is in use" do
      Danbooru.config.stubs(:http_proxy).returns("http://proxy.example.com:8080")
      assert_refused(Danbooru::Http.external.get("https://#{REFUSED}/"))
      assert_equal([], @sent)
    end

    should "never use a proxy on a refused host" do
      assert_refused(Danbooru::Http.proxy(url: "http://proxy.#{REFUSED}:8080").get("https://example.com/"))
      assert_equal([], @sent)
    end

    should "say the site is refused when downloading or raising" do
      error = assert_raises(Danbooru::Http::DownloadError) { Danbooru::Http.external.download_media("https://#{REFUSED}/a.png") }
      assert_match(/refused site.*Fix:/, error.message)

      error = assert_raises(Danbooru::Http::Error) { Danbooru::Http.external.get!("https://#{REFUSED}/") }
      assert_match(/refused site.*Fix:/, error.message)
      assert_nil(Danbooru::Http.external.parsed_get("https://#{REFUSED}/"))
      assert_equal([], @sent)
    end
  end

  context "A redirect to a refused host:" do
    should "never be followed, on the direct or the proxied route" do
      [
        Danbooru::Http.external,
        Danbooru::Http.proxy(url: "http://proxy.example.com:8080"),
      ].product(["https://#{REFUSED}/", "https://media.#{REFUSED}/a.png", "http://#{REFUSED.upcase}./", "//#{REFUSED}/x"]).each do |http, location|
        stub_network!(redirects: { "https://example.com/" => location })

        assert_refused(http.get("https://example.com/"))
        assert_equal(["get example.com"], @sent, location)
      end
    end

    should "never be followed on a later hop" do
      stub_network!(redirects: { "https://example.com/" => "https://example.org/", "https://example.org/" => "https://media.#{REFUSED}/" })

      assert_refused(Danbooru::Http.external.get("https://example.com/"))
      assert_equal(["get example.com", "get example.org"], @sent)
    end

    should "only be read, not followed, by redirect_url" do
      stub_network!(redirects: { "https://example.com/" => "https://#{REFUSED}/" })

      assert_equal(REFUSED, Danbooru::Http.external.redirect_url("https://example.com/").host)
      assert_equal(["head example.com"], @sent)
    end
  end

  context "Other hosts:" do
    should "still be reached, including names that only resemble a refused one" do
      stub_network!

      ["pawoo.net", "not#{REFUSED}", "#{REFUSED}.example.com", "example.com"].each do |host|
        assert_equal(200, Danbooru::Http.external.get("https://#{host}/#{REFUSED}").code, host)
      end
      assert_equal(4, @sent.size)
    end

    should "be refused in a Unicode spelling a name lookup would read as the host" do
      ["\u3002", "\uff0e", "\uff61"].each do |dot|
        assert(Danbooru::RefusedHosts.refused?("media.#{REFUSED.sub(".", dot)}"))
      end
      assert(Danbooru::RefusedHosts.refused?(REFUSED.tr("a-z", "\uff41-\uff5a")))
    end

    should "not be refused when blank or not a name" do
      [nil, "", ".", "127.0.0.1", "[::1]", "\xFF"].each do |host|
        assert_not(Danbooru::RefusedHosts.refused?(host))
      end
      assert_not(Danbooru::RefusedHosts.refused_url?("text about #{REFUSED} with no link"))
    end
  end

  context "The source extractor for a refused host:" do
    should "not be a site's own, and fetch nothing" do
      stub_network!
      extractor = Source::Extractor.find("https://#{REFUSED}/@a/107866090743238456")

      assert_instance_of(Source::Extractor::Null, extractor)
      assert_raises(Danbooru::Http::DownloadError) { extractor.download_file!("https://#{REFUSED}/a.png") }
      extractor.to_h
      assert_equal([], @sent)
    end
  end

  context "A link to a refused host:" do
    setup do
      stub_network!
      @user = create(:user)
    end

    should "be refused as an upload source or referer, before a job is queued" do
      assert_no_enqueued_jobs do
        upload = Upload.create(uploader: @user, source: "https://media.#{REFUSED}/a.png")
        assert_match(/refused site/, upload.errors[:source].join)

        upload = Upload.create(uploader: @user, source: "https://example.com/a.png", referer_url: "https://#{REFUSED}/@a/1")
        assert_match(/refused site/, upload.errors[:referer_url].join)
      end
      assert_equal([], @sent)
    end

    should "fail an upload or an asset that was queued before the refusal" do
      upload = create(:upload, uploader: @user, source: "https://example.com/a.png")
      upload.update_columns(source: "https://#{REFUSED}/a.png")
      Upload.find(upload.id).process_upload!
      assert_equal("error", upload.reload.status)
      assert_match(/refused site/, upload.error)

      asset = create(:upload_media_asset, upload: upload, source_url: "https://example.com/a.png", media_asset: nil)
      asset.update_columns(source_url: "https://media.#{REFUSED}/a.png")
      asset = UploadMediaAsset.find(asset.id)
      asset.process_upload!
      assert_equal("failed", asset.reload.status)
      assert_match(/refused site/, asset.error)

      assert_equal([], @sent.grep(/#{Regexp.escape(REFUSED)}/i))
    end

    should "be refused as a replacement" do
      post = create(:post, uploader: @user, source: "https://example.com/1")
      replacement = as(@user) { PostReplacement.create(post: post, creator: @user, replacement_url: "https://#{REFUSED}/a.png") }

      assert_match(/refused site/, replacement.errors.full_messages.join)
      assert_equal("https://example.com/1", post.reload.source)
      assert_equal([], @sent)
    end

    should "be refused as a post's source, while a post that already has one can still be saved" do
      post = create(:post, uploader: @user, source: "https://example.com/1")
      as(@user) { post.update(source: "https://#{REFUSED}/@a/1") }
      assert_match(/refused site/, post.errors[:source].join)

      post.reload.update_columns(source: "https://#{REFUSED}/@a/1")
      post = Post.find(post.id)
      as(@user) { post.update!(rating: "s") }
      as(@user) { post.update!(source: "") }
      assert_equal("", post.reload.source)
      assert_equal([], @sent)
    end

    should "be refused as an artist's URL" do
      artist = build(:artist, url_string: "https://#{REFUSED}/@a")
      assert_not(artist.valid?)
      assert_match(/refused site/, artist.errors.full_messages.join)

      url = ArtistURL.new(artist: create(:artist), url: "https://www.#{REFUSED}/@a")
      assert_not(url.valid?)
      assert_match(/refused site/, url.errors[:url].join)
      assert_equal([], @sent)
    end
  end

  context "An email address on a refused host:" do
    should "be undeliverable without a name lookup or a connection" do
      Resolv::DNS.any_instance.expects(:getresource).never
      Net::SMTP.expects(:new).never

      assert(Danbooru::EmailAddress.new("a@#{REFUSED}").undeliverable?)
      assert(Danbooru::EmailAddress.new("a@mail.#{REFUSED}").undeliverable?)
    end
  end
end
