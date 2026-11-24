require "test_helper"

# test/test_helpers/outside_site_helper.rb, test/fourier_network_guard.rb and
# test/files/outside_uncovered.txt: no test contacts an outside site (operator
# ruling 2026-11-24). Every name here is made up, in our own zone.
class OutsideSiteHelperTest < ActiveSupport::TestCase
  # A stand-in for a finished test: what the verdict reads and rewrites, without
  # running a second Minitest inside this one. It never reaches `super`.
  class FinishedTest
    include OutsideSiteHelper

    attr_accessor :failures, :name

    def initialize(failures: [], name: "test_made_up", extractor: false)
      @failures = failures
      @name = name
      @extractor = extractor
    end

    def metadata
      @metadata ||= {}
    end

    def is_a?(klass)
      klass == ActiveSupport::ExtractorTestCase ? @extractor : super
    end

    def judge
      judge_outside_sites
      self
    end
  end

  HOST = "made-up.41chan.net"
  KEY = "#{FinishedTest.name}#test_made_up".freeze

  def failed
    [Minitest::Assertion.new("Expected: 200")]
  end

  def skipped
    [Minitest::Skip.new("its own reason")]
  end

  # Judges a test that asked for these hosts and logins.
  def judge(hosts: [], asked: {}, listed: nil, writing: false, **finished)
    OutsideSiteHelper.stubs(:listed).returns(listed ? { KEY => listed } : {})
    OutsideSiteHelper.stubs(:writing?).returns(writing)
    OutsideSiteHelper.ledger.concat(hosts)
    OutsideSiteHelper.credentials_asked.merge!(asked)
    FinishedTest.new(**finished).judge
  ensure
    OutsideSiteHelper.unstub(:listed, :writing?)
  end

  def assert_uncovered(reason, run)
    assert_equal([Minitest::Skip], run.failures.map(&:class))
    assert_operator(run.failures.first.message, :start_with?, "uncovered:")
    assert_equal(reason, run.metadata[:uncovered])
  end

  def assert_failed(pattern, run)
    assert_instance_of(Minitest::Assertion, run.failures.first)
    assert_match(pattern, run.failures.first.message)
    assert_nil(run.metadata[:uncovered])
  end

  def assert_untouched(failures, run)
    assert_equal(failures, run.failures)
    assert_nil(run.metadata[:uncovered])
  end

  setup do
    @ledger = OutsideSiteHelper.ledger.dup
    OutsideSiteHelper.ledger.clear
    OutsideSiteHelper.credentials_asked.clear
  end

  # What these tests record is taken back before this test itself is judged; a
  # host recorded before it stays.
  teardown do
    OutsideSiteHelper.ledger.replace(@ledger)
    OutsideSiteHelper.credentials_asked.clear
  end

  context "A test that went outside" do
    should "fail when it is not listed, whatever its own outcome" do
      assert_failed(/needs an outside site \(made-up.41chan.net\).*Fix:/m, judge(hosts: [HOST]))
      assert_failed(/needs an outside site/, judge(hosts: [HOST], failures: failed))
      assert_failed(/needs an outside site/, judge(hosts: [HOST], failures: skipped))
    end

    should "be uncovered when it is listed, whatever its own outcome" do
      assert_uncovered("site", judge(hosts: [HOST], listed: "site"))
      assert_uncovered("site", judge(hosts: [HOST], listed: "site", failures: failed))
      assert_uncovered("site", judge(hosts: [HOST], listed: "site", failures: skipped))
    end

    should "be uncovered when the list is being written" do
      assert_uncovered("site", judge(hosts: [HOST], writing: true))
    end

    should "print each host once, and a refused host not at all" do
      hosts = [HOST, HOST, Danbooru::RefusedHosts::HOSTS.first, "192.0.2.1", "a.41chan.net"]
      message = judge(hosts:).failures.first.message

      assert_match(/\(made-up.41chan.net, a refused host, an address, and 1 more\)/, message)
      assert_not_includes(message, Danbooru::RefusedHosts::HOSTS.first)
    end

    should "leave nothing for the next test" do
      judge(hosts: [HOST], asked: { "Pixiv" => nil })

      assert_empty(OutsideSiteHelper.ledger)
      assert_empty(OutsideSiteHelper.credentials_asked)
    end
  end

  context "A test that stayed inside" do
    should "keep its own outcome when it is not listed" do
      assert_untouched([], judge)
      failures = failed
      assert_untouched(failures, judge(failures:))
      skips = skipped
      assert_untouched(skips, judge(failures: skips))
    end

    should "fail when it is listed and ran" do
      assert_failed(/listed in outside_uncovered.txt but ran/, judge(listed: "site"))
      assert_failed(/listed in outside_uncovered.txt but ran/, judge(listed: "site", failures: failed))
    end

    should "lose its line when the list is being written" do
      assert_untouched([], judge(listed: "site", writing: true))
    end
  end

  context "A test that skipped for a login" do
    should "be uncovered, with the login it needs, when it is listed" do
      assert_uncovered("login:Pixiv", judge(asked: { "Pixiv" => nil }, failures: skipped, listed: "login:Pixiv"))
    end

    should "fail when it is not listed" do
      assert_failed(/needs a login: Pixiv/, judge(asked: { "Pixiv" => nil }, failures: skipped))
    end

    should "keep its own skip when the login was there" do
      skips = skipped
      assert_untouched(skips, judge(asked: { "Pixiv" => { "a" => "b" } }, failures: skips))
    end
  end

  context "An extractor test that skips itself" do
    should "be uncovered when it is listed, and fail when it is not" do
      assert_uncovered("site", judge(failures: skipped, extractor: true, listed: "site"))
      assert_failed(/skips itself/, judge(failures: skipped, extractor: true))
    end
  end

  context "Every way out" do
    should "be refused, and recorded" do
      {
        Resolv::ResolvError => [
          -> { Resolv.getaddress(HOST) },
          -> { Resolv::DNS.new.getresource(HOST, Resolv::DNS::Resource::IN::MX) },
        ],
        Errno::ENETUNREACH => [
          -> { TCPSocket.new(HOST, 80) },
          -> { TCPSocket.open("192.0.2.1", 80) },
          -> { Socket.tcp(HOST, 80) },
          -> { Net::HTTP.get(URI("http://#{HOST}/")) },
        ],
      }.each do |error, ways|
        ways.each do |way|
          raised = assert_raises(error, SocketError) { way.call }
          assert_match(/refused by the test suite/, raised.message)
          assert_equal(1, OutsideSiteHelper.ledger.uniq.size)
          OutsideSiteHelper.ledger.clear
        end
      end
    end

    should "be recorded when the app swallows the refusal" do
      assert_equal(598, Danbooru::Http.new.get("http://#{HOST}/").status)
      assert_equal([HOST], OutsideSiteHelper.ledger.uniq)
    end
  end

  context "A host" do
    should "be outside unless it is this machine, a service or a private address" do
      [HOST, "192.0.2.1", "8.8.8.8", "[2001:db8::1]", "1.2.0.192.in-addr.arpa"].each do |host|
        assert(OutsideSiteHelper.outside?(host), host)
      end

      ["", nil, "localhost", "postgres", "127.0.0.11", "172.18.0.2", "::1", "0.0.0.0", "2.0.18.172.in-addr.arpa"].each do |host|
        assert_not(OutsideSiteHelper.outside?(host), host.inspect)
      end
    end
  end

  context "The list" do
    should "name tests that exist, with a reason, and no host" do
      assert(OutsideSiteHelper::LIST.exist?)
      defined = Rails.root.glob("test/**/*_test.rb").flat_map { |file| file.read.scan(/^\s*class ([\w:]+)/).flatten.map { |name| name.split("::").last } }.to_set
      loaded = Minitest::Runnable.runnables.index_by(&:name)

      OutsideSiteHelper.read_list.each do |key, reason|
        klass, name = key.split("#", 2)
        assert_match(/\A(site|login:\S.*)\z/, reason.to_s, key)
        assert_includes(SiteCredential.sites.keys, reason.delete_prefix("login:"), key) if reason.start_with?("login:")
        assert_includes(defined, klass.split("::").last, key)
        assert_empty(Danbooru::RefusedHosts::HOSTS.select { |host| key.include?(host) })
        next unless loaded[klass]

        assert_includes(loaded[klass].runnable_methods.map { |method| OutsideSiteHelper.key(klass, method) }, key) if name
      end
    end

    should "be written with its header, sorted, in ASCII, and read back" do
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir).join("list.txt")
        path.write("# a header\nOld#test\tsite\n")
        key = OutsideSiteHelper.key("B", "test_: caf\u00e9 https://example.com/a#b should work. ")
        OutsideSiteHelper.write_list({ key => "site", "A#test" => "login:Pixiv" }, path)

        assert_equal("# a header\nA#test\tlogin:Pixiv\nB#test_: caf\\u{e9} https://example.com/a#b should work.\tsite\n", path.read)
        assert_equal({ "A#test" => "login:Pixiv", key => "site" }, OutsideSiteHelper.read_list(path))
      end
    end
  end

  context "The report" do
    # Its runs are made up: a run with OUTSIDE_LIST=write must not list them.
    setup { OutsideSiteHelper.stubs(:writing?).returns(false) }
    teardown { OutsideSiteHelper.unstub(:writing?) }

    should "count and name every uncovered test" do
      result = Minitest::Result.new("test_made_up")
      result.klass = FinishedTest.name
      result.metadata[:uncovered] = "site"
      result.failures = [Minitest::Skip.new("uncovered: #{HOST}")]
      reporter = OutsideSiteHelper::Reporter.new
      reporter.io = StringIO.new
      reporter.start
      reporter.record(result)
      reporter.report

      assert_includes(reporter.io.string, "\nuncovered: 1 test(s) ")
      assert_includes(reporter.io.string, "\n  #{KEY} -- #{HOST}\n")
    end

    should "say so when there are none" do
      reporter = OutsideSiteHelper::Reporter.new
      reporter.io = StringIO.new
      reporter.start
      reporter.report

      assert_includes(reporter.io.string, "\nuncovered: 0 test(s) ")
    end
  end

  context "The network guard" do
    setup do
      @header = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
      @subnet = "eth0\t000016AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n"
      @default = "eth0\t00000000\t010016AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n"
      @lo = "#{"0" * 32} 00 #{"0" * 32} 00 #{"0" * 32} ffffffff 00000001 00000000 00200200       lo\n"
    end

    should "see a default route in either family" do
      assert_equal(["eth0"], FourierNetworkGuard.default_routes(ipv4: @header + @subnet + @default, ipv6: @lo))
      assert_equal(["eth1"], FourierNetworkGuard.default_routes(ipv4: @header + @subnet, ipv6: @lo + @lo.sub(/lo$/, "eth1")))
    end

    should "see none on an internal network" do
      assert_empty(FourierNetworkGuard.default_routes(ipv4: @header + @subnet, ipv6: @lo))
    end
  end
end
