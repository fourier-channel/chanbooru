require "test_helper"

# test/test_helpers/live_site_test_helper.rb: a test that needs a live outside
# site, failing because the site missed, is "not achieved" and never blocks a
# gate (operator ruling 2026-11-21). Everything else that fails stays a FAIL.
class LiveSiteTestHelperTest < ActiveSupport::TestCase
  # A stand-in for a finished test: what classify_live_site_miss reads and
  # rewrites, without running a second Minitest inside this one.
  class FinishedTest
    include LiveSiteTestHelper

    attr_accessor :failures

    def initialize(failures)
      @failures = failures
    end

    def metadata
      @metadata ||= {}
    end

    def classify
      classify_live_site_miss
      self
    end
  end

  def failed(message = "Expected: 200\n  Actual: 502")
    FinishedTest.new([Minitest::Assertion.new(message)])
  end

  def answered(url, status)
    LiveSiteTestHelper.record(url, status)
  end

  # The words of Reddit's block page as vesper was answered on 2026-11-22.
  REDDIT_BLOCK_PAGE = "<html><body><p>You've been blocked by network security.</p>" \
                      "<p>If you think you've been blocked by mistake, file a ticket below and we'll look into it.</p></body></html>"

  def response_with(url, status, body)
    ::HTTP::Response.new(status: status, version: "1.1", body: body, request: ::HTTP::Request.new(verb: :get, uri: url))
  end

  # The title baraag.net's status API was answered with on 2026-11-24.
  SEIZURE_NOTICE = "<html><head><title>Seized by the Federal Bureau of Investigation</title></head><body></body></html>"

  # Records an answer as the Recorder does, its statement read from its body.
  def answered_with(url, status, body)
    response = response_with(url, status, body).flush
    LiveSiteTestHelper.record(url, status, LiveSiteTestHelper.statement(url, response, buffered: true))
  end

  def assert_not_achieved(run)
    assert_equal(1, run.failures.size)
    assert_kind_of(Minitest::Skip, run.failures.first)
    assert(run.failures.first.message.start_with?("not achieved:"), run.failures.first.message)
  end

  def assert_still_failed(run)
    assert_equal(1, run.failures.size)
    assert_not_kind_of(Minitest::Skip, run.failures.first)
  end

  def finished_result(name, failures: [], reached: false)
    Minitest::Result.new(name).tap do |r|
      r.klass = "SomeLiveTest"
      r.failures = failures
      r.metadata = { reached_outside_site: true } if reached
    end
  end

  def printed(*results)
    reporter = LiveSiteTestHelper::NotAchievedReporter.new
    reporter.io = StringIO.new
    reporter.start
    results.each { |r| reporter.record(r) }
    reporter.report
    reporter.io.string
  end

  setup { LiveSiteTestHelper.answers.clear }
  # This test's own answers are made up, so its own classification must not
  # count it as having reached an outside site.
  teardown { LiveSiteTestHelper.answers.clear }

  context "a failed test" do
    should "be not achieved when an outside site answered a 5xx, naming the site, status and reason" do
      answered("https://httpbingo.org/status/200", 502)
      run = failed.classify

      assert_not_achieved(run)
      assert_equal("not achieved: httpbingo.org answered 502 -- Expected: 200 Actual: 502", run.failures.first.message)
    end

    should "be not achieved when an outside site gave no answer (timeout, connection, DNS)" do
      [597, 598, 599].each do |status|
        LiveSiteTestHelper.answers.clear
        answered("https://baraag.net/@danbooru/1", status)
        assert_not_achieved(failed.classify)
      end
    end

    should "be not achieved when an error, not an assertion, followed the miss" do
      answered("https://img-sketch.pixiv.net/a.jpg", 598)
      error = begin
        raise "boom"
      rescue RuntimeError => e
        Minitest::UnexpectedError.new(e)
      end
      assert_not_achieved(FinishedTest.new([error]).classify)
    end

    should "stay failed when every outside answer was a success: the reading is ours" do
      answered("https://www.weibo.com/1/2", 200)
      assert_still_failed(failed("doesn't contain any images").classify)
    end

    should "stay failed on a 4xx, the site's definite answer about our request" do
      answered("https://httpbingo.org/status/404", 404)
      assert_still_failed(failed.classify)
    end

    should "be not achieved when an outside site's 4xx says it refused this network, naming why" do
      url = "https://www.reddit.com/comments/ttyccp.json"
      answered_with(url, 403, REDDIT_BLOCK_PAGE)
      run = failed("Expected: [...] Actual: []").classify

      assert_not_achieved(run)
      assert_equal("not achieved: www.reddit.com answered 403 (blocked by network security: the site's page says it " \
                   "blocked this network, not the request) -- Expected: [...] Actual: []", run.failures.first.message)
    end

    should "stay failed on a 4xx whose answer does not say it refused this network" do
      answered_with("https://www.reddit.com/comments/ttyccp.json", 403, "<html><title>Forbidden</title></html>")
      assert_still_failed(failed.classify)
    end

    should "not count a refusal's words on any other status" do
      [200, 401, 404, 429].each do |status|
        LiveSiteTestHelper.answers.clear
        answered_with("https://www.reddit.com/comments/ttyccp.json", status, REDDIT_BLOCK_PAGE)
        assert_still_failed(failed("doesn't contain any images").classify)
      end
    end

    should "be not achieved when a site that is gone answers with its notice, naming why" do
      answered_with("https://baraag.net/api/v1/statuses/107866090743238456", 200, SEIZURE_NOTICE)
      run = failed("undefined method 'dig'").classify

      assert_not_achieved(run)
      assert_equal("not achieved: baraag.net answered 200 (Seized by the Federal Bureau of Investigation: the domain was seized " \
                   "and serves this notice at every address) -- undefined method 'dig'", run.failures.first.message)
    end

    should "count that notice on the site's subdomains, and on no other host" do
      answered_with("https://media.baraag.net/media_attachments/1.png", 200, SEIZURE_NOTICE)
      assert_not_achieved(failed.classify)

      %w[https://pawoo.net/api/v1/statuses/1 https://notbaraag.net/1 https://baraag.net.example.com/1].each do |url|
        LiveSiteTestHelper.answers.clear
        answered_with(url, 200, SEIZURE_NOTICE)
        assert_still_failed(failed.classify)
      end
    end

    should "stay failed when the site answers without that notice, or the notice comes on another status" do
      url = "https://baraag.net/api/v1/statuses/107866090743238456"
      [[200, '{"id":"107866090743238456"}'], [200, "<html><title>Baraag</title></html>"], [403, SEIZURE_NOTICE], [404, SEIZURE_NOTICE]].each do |status, body|
        LiveSiteTestHelper.answers.clear
        answered_with(url, status, body)
        assert_still_failed(failed.classify)
      end
    end

    should "not look in a body the request streamed" do
      url = "https://www.reddit.com/comments/ttyccp.json"
      assert_nil(LiveSiteTestHelper.statement(url, response_with(url, 403, REDDIT_BLOCK_PAGE), buffered: false))
    end

    should "stay failed on our own refusals: certificate, prohibited address, size, redirect limit" do
      [590, 591, 595, 596].each do |status|
        LiveSiteTestHelper.answers.clear
        answered("https://127.0.0.1.nip.io", status)
        assert_still_failed(failed.classify)
      end
    end

    should "stay failed when the 5xx came from this machine or the private network" do
      %w[http://127.0.0.1:3000/ http://10.0.0.5/ http://localhost/ http://iqdb:5588/ http://[::1]/].each do |url|
        LiveSiteTestHelper.answers.clear
        answered(url, 502)
        assert_still_failed(failed.classify)
      end
    end

    should "stay failed when no site was reached at all" do
      assert_still_failed(failed.classify)
    end

    should "stay failed when the 5xx was a stub on the transport" do
      HTTP::Client.any_instance.stubs(:perform).raises(HTTP::ConnectionError)
      response = Danbooru::Http.get("https://httpbingo.org/status/200")
      assert_equal(598, response.status)

      assert_still_failed(failed.classify)
    end

    should "be recorded as Danbooru::Http answers it, here a 502 from a local server" do
      body = "bad gateway"
      server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      server.mount_proc("/") do |_req, res|
        res.status = 502
        res.body = body
      end
      thread = Thread.new { server.start }
      Danbooru::Http.get("http://127.0.0.1:#{server.config[:Port]}/")

      assert_equal([["127.0.0.1", 502, false, nil]], LiveSiteTestHelper.answers.map(&:to_a))
    ensure
      server&.shutdown
      thread&.join
    end

    should "be recorded with the refusal Danbooru::Http's answer carries, buffered or streamed" do
      server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      server.mount_proc("/") do |_req, res|
        res.status = 403
        res.body = REDDIT_BLOCK_PAGE
      end
      thread = Thread.new { server.start }
      url = "http://127.0.0.1:#{server.config[:Port]}/comments/ttyccp.json"
      Danbooru::Http.get(url)
      streamed = Danbooru::Http.new.request(:get, url, buffer: false)

      # read as a stream: had the Recorder read this body, this raises "body has already been consumed"
      assert_match(/blocked by network security/, streamed.body.readpartial)
      assert_equal([[403, "blocked by network security: the site's page says it blocked this network, not the request"], [403, nil]],
                   LiveSiteTestHelper.answers.map { |a| [a.status, a.statement] })
    ensure
      server&.shutdown
      thread&.join
    end
  end

  context "a passing test" do
    should "be left a pass, and marked as having reached an outside site" do
      answered("https://httpbingo.org/status/200", 502)
      run = FinishedTest.new([]).classify

      assert_equal([], run.failures)
      assert_equal(true, run.metadata[:reached_outside_site])
    end
  end

  context "the not-achieved reporter" do
    should "print the count and one column-0 line per miss, on every run" do
      miss = Minitest::Skip.new("not achieved: httpbingo.org answered 502 -- Expected: 200 Actual: 502")
      out = printed(
        finished_result("test_a", reached: true),
        finished_result("test_b", failures: [miss], reached: true),
        finished_result("test_c", failures: [Minitest::Skip.new("Login credentials not configured")]),
      )

      assert_match(/^live outside sites: 2 test\(s\) reached one; 1 not achieved /, out)
      assert_equal(["not achieved: SomeLiveTest#test_b -- httpbingo.org answered 502 -- Expected: 200 Actual: 502"],
                   out.lines.map(&:chomp).grep(/\Anot achieved: /))
    end

    should "say none were missed when none were, with no not-achieved line" do
      out = printed(finished_result("test_a", reached: true))

      assert_match(/^live outside sites: 1 test\(s\) reached one; 0 not achieved /, out)
      assert_empty(out.lines.grep(/\Anot achieved: /))
    end
  end
end
