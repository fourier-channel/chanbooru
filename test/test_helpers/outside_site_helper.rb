require "ipaddr"
require "resolv"
require "socket"

# Fork. NO TEST CONTACTS AN OUTSIDE SITE (operator ruling 2026-11-24, memory
# tests-contact-no-outside-site). The container has no route out (the `test`
# service, test/fourier_network_guard.rb); this file is what NAMES the test.
#
# A name lookup or a connect to an outside host is written to the running
# test's ledger and refused with an ordinary connection error. The app may
# swallow that error -- Danbooru::Http makes it a 598, jobs rescue it -- so the
# verdict is read from the ledger after the test, never from its outcome.
#
# A test that needs an outside site is NOT RUN (operator ruling 2026-11-25): no
# setup, no body, no refused request. It stands in test/files/outside_not_run.txt,
# one "Class#name<TAB>reason" a line, the reason `site` or `login:<SiteCredential
# site>`, and NotRun leaves it out of what its class runs, in every run:
#
#   listed                                    not run, counted
#   not listed, went outside or could not     FAIL: stub it, or list it
#
# The file is public, so it holds test names and those reasons only, never a host.
module OutsideSiteHelper
  PREFIX = "not run:"
  LIST = Rails.root.join("test/files/outside_not_run.txt")
  SITE = "site"
  LOGIN = "login:"

  class << self
    # Each parallel worker is its own process, so one list is one test's. What
    # is left over from between two tests counts against the next one.
    def ledger
      @ledger ||= []
    end

    # The listed tests left out of this run.
    def not_run
      @not_run ||= Set.new
    end

    # The SiteCredential lookups the running test made, as { site => result }.
    def credentials_asked
      @credentials_asked ||= {}
    end

    # A public host: not a bare service name, this machine or a private range.
    def outside?(host)
      host = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
      return false if host.empty? || host.match?(/\A[^.:]*\z/)
      return outside?(reversed_address(host)) if host.match?(/\.(in-addr|ip6)\.arpa\.?\z/)

      ip = IPAddr.new(host)
      !(ip.private? || ip.loopback? || ip.link_local? || ip.to_i.zero?)
    rescue IPAddr::InvalidAddressError
      true
    end

    # The address an in-addr.arpa or ip6.arpa name asks about.
    def reversed_address(name)
      labels = name.delete_suffix(".").split(".")[0...-2].reverse
      name.include?("ip6.arpa") ? labels.each_slice(4).map(&:join).join(":") : labels.join(".")
    end

    def refuse(host, error)
      return unless outside?(host)

      ledger << host.to_s
      raise error, "refused by the test suite: #{shown(host)} is an outside site (test/test_helpers/outside_site_helper.rb)"
    end

    # What a log may print for a host. The log is not published, but a refused
    # host is named in one file only, and an address may be a setting's.
    def shown(host)
      return "a refused host" if Danbooru::RefusedHosts.refused?(host)
      IPAddr.new(host.to_s.delete("[]"))
      "an address"
    rescue IPAddr::InvalidAddressError
      host.to_s.match?(/\.(in-addr|ip6)\.arpa\.?\z/) ? "an address" : host.to_s
    end

    # Test names hold addresses and Unicode; the file is ASCII, one line each.
    def key(klass, name)
      "#{klass}##{name.strip}".each_char.map { |c| c.match?(/[ -~]/) ? c : c.codepoints.map { |p| format("\\u{%x}", p) }.join }.join
    end

    def listed
      @listed ||= read_list
    end

    def read_list(path = LIST)
      return {} unless path.exist?
      path.readlines(chomp: true).reject { |line| line.start_with?("#") || line.empty? }.to_h { |line| line.split("\t", 2) }
    end

    # Why a finished test could not do without an outside site, or nil.
    def need(hosts:, missing_login:, skipped:, extractor:)
      if hosts.any?
        sites = hosts.map { |host| shown(host) }.uniq
        sites = sites.first(3) + ["and #{sites.size - 3} more"] if sites.size > 3
        sites.join(", ")
      elsif skipped && missing_login
        "needs a login: #{missing_login}"
      elsif skipped && extractor
        "skips itself"
      end
    end

    def reason_for(missing_login)
      missing_login ? "#{LOGIN}#{missing_login}" : SITE
    end
  end

  # The listed tests are never among a class's tests, so Minitest never makes one.
  module NotRun
    def runnable_methods
      super.reject do |method|
        key = OutsideSiteHelper.key(name, method)
        OutsideSiteHelper.listed.key?(key) && OutsideSiteHelper.not_run.add(key)
      end
    end
  end

  module Lookups
    def each_address(name, &)
      OutsideSiteHelper.refuse(name, Resolv::ResolvError) unless name.to_s.match?(Resolv::AddressRegex)
      super
    end
  end

  module Queries
    def fetch_resource(name, ...)
      OutsideSiteHelper.refuse(name, Resolv::ResolvError)
      super
    end
  end

  module Connects
    def initialize(host = nil, ...)
      OutsideSiteHelper.refuse(host, Errno::ENETUNREACH)
      super
    end
  end

  module SocketConnects
    def tcp(host, ...)
      OutsideSiteHelper.refuse(host, Errno::ENETUNREACH)
      super
    end
  end

  module Credentials
    def for_site(site, ...)
      super.tap { |found| OutsideSiteHelper.credentials_asked[site] = found }
    end
  end

  def after_teardown
    super
  ensure
    judge_outside_sites
  end

  private

  def judge_outside_sites
    hosts = OutsideSiteHelper.ledger.dup
    asked = OutsideSiteHelper.credentials_asked.dup
    OutsideSiteHelper.ledger.clear
    OutsideSiteHelper.credentials_asked.clear

    skip = failures.find { |f| f.is_a?(Minitest::Skip) }
    missing_login = asked.reverse_each.find { |_site, found| found.blank? }&.first if skip
    why = OutsideSiteHelper.need(hosts:, missing_login:, skipped: skip.present?, extractor: is_a?(ActiveSupport::ExtractorTestCase))
    return unless why

    failure = Minitest::Assertion.new(
      "This test needs an outside site (#{why}) and no test contacts one. Fix: give it a stub or a local server; or, if it " \
      "cannot do without the site, add its line to #{OutsideSiteHelper::LIST.relative_path_from(Rails.root)} (a tab before the " \
      "reason) and it is not run: #{OutsideSiteHelper.key(self.class.name, name)}\t#{OutsideSiteHelper.reason_for(missing_login)}",
    )
    failure.set_backtrace((skip || failures.first)&.backtrace || ["test/files/#{LIST.basename}"])
    self.failures = [failure] + failures.grep_v(Minitest::Skip)
  end

  # Counts the tests not run, after every run, starting at column 0: coherence's
  # gate lifts the line onto its verdict. And a run of no test is not a pass.
  # Runs in the parent process, which is the one that chooses the tests.
  class Reporter < Minitest::Reporters::BaseReporter
    def report
      super
      io.puts
      io.puts "#{PREFIX} #{OutsideSiteHelper.not_run.size} test(s) need an outside site (operator ruling 2026-11-25)"
      return if tests.any?

      io.puts "FAIL: no test ran, and a run of no test is not a pass."
      io.puts "fix:  name a test file with a test that is not in #{LIST.relative_path_from(Rails.root)}"
    end

    def passed?
      tests.any? && super
    end
  end
end

ActiveSupport::TestCase.singleton_class.prepend(OutsideSiteHelper::NotRun)
Resolv.prepend(OutsideSiteHelper::Lookups)
Resolv::DNS.prepend(OutsideSiteHelper::Queries)
TCPSocket.prepend(OutsideSiteHelper::Connects)
Socket.singleton_class.prepend(OutsideSiteHelper::SocketConnects)
SiteCredential.singleton_class.prepend(OutsideSiteHelper::Credentials)
