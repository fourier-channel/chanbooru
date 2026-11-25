require "test_helper"

# test/test_helpers/outside_site_helper.rb, test/fourier_network_guard.rb and
# test/files/outside_not_run.txt: no test contacts an outside site (operator
# ruling 2026-11-24), and one that needs to is not run (2026-11-25). Every name here is made up, in our own zone.
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
  def judge(hosts: [], asked: {}, **finished)
    OutsideSiteHelper.ledger.concat(hosts)
    OutsideSiteHelper.credentials_asked.merge!(asked)
    FinishedTest.new(**finished).judge
  end

  def assert_failed(pattern, run)
    assert_instance_of(Minitest::Assertion, run.failures.first)
    assert_match(pattern, run.failures.first.message)
  end

  def assert_untouched(failures, run)
    assert_equal(failures, run.failures)
  end

  # Not stubs: a test run in here ends every stub, its own and this one's.
  def with_list(listed)
    was = OutsideSiteHelper.instance_variables.index_with { |ivar| OutsideSiteHelper.instance_variable_get(ivar) }
    OutsideSiteHelper.instance_variable_set(:@listed, listed)
    OutsideSiteHelper.instance_variable_set(:@not_run, @not_run = Set.new)
    yield
  ensure
    OutsideSiteHelper.instance_variable_set(:@listed, was[:@listed])
    OutsideSiteHelper.instance_variable_set(:@not_run, was[:@not_run])
  end

  # A test class of its own, run through Minitest's own route in this process.
  # Not an ActiveSupport one: that would open a second set of fixtures here.
  # @return [Array<Symbol>] what of it executed, and the reporter that saw it
  def run_made_up_tests(listed:)
    executed = []
    klass = Class.new(Minitest::Test) do
      def self.name = "MadeUpTest"
      def self.run_order = :sorted
      def self.run(...) = Minitest::Runnable.run(...)
      singleton_class.prepend(OutsideSiteHelper::NotRun)

      define_method(:setup) { executed << :"setup_of_#{name}" }
      define_method(:test_listed) { executed << :body_of_test_listed }
      define_method(:test_other) { executed << :body_of_test_other }
      define_method(:teardown) { executed << :"teardown_of_#{name}" }
    end
    reporter = OutsideSiteHelper::Reporter.new
    reporter.io = StringIO.new
    with_list(listed) do
      reporter.start
      klass.run_suite(reporter)
      reporter.report
    end
    [executed, reporter]
  ensure
    Minitest::Runnable.runnables.delete(klass)
  end

  LISTED_RAN = %i[setup_of_test_listed body_of_test_listed teardown_of_test_listed].freeze
  OTHER_RAN = %i[setup_of_test_other body_of_test_other teardown_of_test_other].freeze

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
    should "fail, whatever its own outcome" do
      assert_failed(/needs an outside site \(made-up.41chan.net\).*Fix:/m, judge(hosts: [HOST]))
      assert_failed(/needs an outside site/, judge(hosts: [HOST], failures: failed))
      assert_failed(/needs an outside site/, judge(hosts: [HOST], failures: skipped))
    end

    should "be given the line that lists it" do
      assert_includes(judge(hosts: [HOST]).failures.first.message, "#{KEY}\tsite")
      assert_includes(judge(asked: { "Pixiv" => nil }, failures: skipped).failures.first.message, "#{KEY}\tlogin:Pixiv")
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
    should "keep its own outcome" do
      assert_untouched([], judge)
      failures = failed
      assert_untouched(failures, judge(failures:))
      skips = skipped
      assert_untouched(skips, judge(failures: skips))
    end
  end

  context "A test that skipped for a login" do
    should "fail, naming the login" do
      assert_failed(/needs a login: Pixiv/, judge(asked: { "Pixiv" => nil }, failures: skipped))
    end

    should "keep its own skip when the login was there" do
      skips = skipped
      assert_untouched(skips, judge(asked: { "Pixiv" => { "a" => "b" } }, failures: skips))
    end
  end

  context "An extractor test that skips itself" do
    should "fail" do
      assert_failed(/skips itself/, judge(failures: skipped, extractor: true))
    end
  end

  context "A listed test" do
    should "run neither its setup, its body nor its teardown, and be counted" do
      executed, reporter = run_made_up_tests(listed: { "MadeUpTest#test_listed" => "site" })

      assert_equal(OTHER_RAN, executed)
      assert_equal(["MadeUpTest#test_listed"], @not_run.to_a)
      assert_equal(["test_other"], reporter.tests.map(&:name))
    end

    # The control: with nothing listed the same class runs both.
    should "run when it is not listed" do
      executed, = run_made_up_tests(listed: {})

      assert_equal(LISTED_RAN + OTHER_RAN, executed)
      assert_empty(@not_run)
    end

    should "be left out of every test class there is" do
      assert_includes(self.class.runnable_methods, name)
      with_list(OutsideSiteHelper.key(self.class, name) => "site") { assert_not_includes(self.class.runnable_methods, name) }
      assert_empty(Minitest::Runnable.runnables.select { |klass| klass <= ActiveSupport::TestCase && klass.singleton_class.ancestors.exclude?(OutsideSiteHelper::NotRun) })
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

        assert_includes(loaded[klass].methods_matching(/^test_/).map { |method| OutsideSiteHelper.key(klass, method) }, key) if name
      end
    end

    should "be read without its header, and key names in ASCII" do
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir).join("list.txt")
        key = OutsideSiteHelper.key("B", "test_: caf\u00e9 https://example.com/a#b should work. ")
        path.write("# a header\nA#test\tlogin:Pixiv\n#{key}\tsite\n")

        assert_equal("B#test_: caf\\u{e9} https://example.com/a#b should work.", key)
        assert_equal({ "A#test" => "login:Pixiv", key => "site" }, OutsideSiteHelper.read_list(path))
      end
    end
  end

  context "The report" do
    should "count the tests not run, and name none" do
      _, reporter = run_made_up_tests(listed: { "MadeUpTest#test_listed" => "site" })

      assert_includes(reporter.io.string, "\nnot run: 1 test(s) ")
      assert_not_includes(reporter.io.string, "MadeUpTest")
      assert(reporter.passed?)
    end

    should "say so when there are none" do
      _, reporter = run_made_up_tests(listed: {})

      assert_includes(reporter.io.string, "\nnot run: 0 test(s) ")
    end

    should "not pass when no test ran" do
      _, reporter = run_made_up_tests(listed: { "MadeUpTest#test_listed" => "site", "MadeUpTest#test_other" => "site" })

      assert_includes(reporter.io.string, "\nnot run: 2 test(s) ")
      assert_includes(reporter.io.string, "FAIL: no test ran")
      assert_not(reporter.passed?)
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
