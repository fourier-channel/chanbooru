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
# A test with no saved copy stands in test/files/outside_uncovered.txt, one
# "Class#name<TAB>reason" a line, the reason `site` or `login:<SiteCredential
# site>`:
#
#   went outside (or could not run)  listed   skipped, printed as uncovered
#   went outside (or could not run)  not      FAIL: save a copy, stub, or list it
#   ran and stayed inside            listed   FAIL: covered now, remove the line
#
# The file is public, so it holds test names and those reasons only, never a
# host. OUTSIDE_LIST=write rewrites the lines of every test that ran.
module OutsideSiteHelper
  PREFIX = "uncovered:"
  LIST = Rails.root.join("test/files/outside_uncovered.txt")
  SITE = "site"
  LOGIN = "login:"

  class << self
    # Each parallel worker is its own process, so one list is one test's. What
    # is left over from between two tests counts against the next one.
    def ledger
      @ledger ||= []
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

    def writing?
      ENV["OUTSIDE_LIST"] == "write"
    end

    def write_list(entries, path = LIST)
      header = path.exist? ? path.readlines.take_while { |line| line.start_with?("#") }.join : ""
      path.write(header + entries.sort.map { |name, reason| "#{name}\t#{reason}\n" }.join)
    end

    # The verdict on a finished test.
    # @return [Array(Symbol, String), nil] the outcome and its message
    def verdict(hosts:, missing_login:, skipped:, extractor:, reason:, writing: false)
      if hosts.any?
        sites = hosts.map { |host| shown(host) }.uniq
        sites = sites.first(3) + ["and #{sites.size - 3} more"] if sites.size > 3
        why = sites.join(", ")
      elsif skipped && missing_login
        why = "needs a login: #{missing_login}"
      elsif skipped && extractor
        why = "skips itself"
      end

      if why
        return [:uncovered, why] if reason || writing
        [:fail, "This test needs an outside site (#{why}) and no test contacts one. Fix: give it a saved copy, a stub or a local " \
                "server; or name it as uncovered with OUTSIDE_LIST=write bash script/run-tests.sh <its file>"]
      elsif reason && !skipped && !writing
        [:fail, "This test is listed in #{LIST.basename} but ran without going outside. Fix: remove its line, " \
                "with OUTSIDE_LIST=write bash script/run-tests.sh <its file>"]
      end
    end

    def reason_for(missing_login)
      missing_login ? "#{LOGIN}#{missing_login}" : SITE
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
    reason = OutsideSiteHelper.listed[OutsideSiteHelper.key(self.class.name, name)]
    outcome, message = OutsideSiteHelper.verdict(
      hosts:, missing_login:, skipped: skip.present?, reason:, writing: OutsideSiteHelper.writing?,
      extractor: is_a?(ActiveSupport::ExtractorTestCase),
    )

    case outcome
    when :uncovered
      metadata[:uncovered] = OutsideSiteHelper.reason_for(missing_login)
      uncovered = Minitest::Skip.new("#{PREFIX} #{message}")
      uncovered.set_backtrace((skip || failures.first)&.backtrace || [])
      self.failures = [uncovered]
    when :fail
      failure = Minitest::Assertion.new(message)
      failure.set_backtrace((skip || failures.first)&.backtrace || ["test/files/#{LIST.basename}"])
      self.failures = [failure] + failures.grep_v(Minitest::Skip)
    end
  end

  # Prints every uncovered test, after every run, starting at column 0:
  # coherence's gate lifts the count onto its verdict. Runs in the parent
  # process; what a worker knew arrives on the result.
  class Reporter < Minitest::Reporters::BaseReporter
    def report
      super
      uncovered = tests.select { |t| t.metadata? && t.metadata[:uncovered] }
      io.puts
      io.puts "#{PREFIX} #{uncovered.size} test(s) have no saved copy of the outside site they need (operator ruling 2026-11-24)"
      uncovered.each do |t|
        io.puts "  #{OutsideSiteHelper.key(t.klass, t.name)} -- #{t.failure.message.to_s.delete_prefix(PREFIX).strip}"
      end
      rewrite(uncovered) if OutsideSiteHelper.writing?
    end

    private

    def rewrite(uncovered)
      ran = tests.map { |t| OutsideSiteHelper.key(t.klass, t.name) }
      entries = OutsideSiteHelper.read_list.except(*ran)
      uncovered.each { |t| entries[OutsideSiteHelper.key(t.klass, t.name)] = t.metadata[:uncovered] }
      OutsideSiteHelper.write_list(entries)
      io.puts "wrote #{LIST.relative_path_from(Rails.root)}: #{entries.size} test(s)"
    end
  end
end

Resolv.prepend(OutsideSiteHelper::Lookups)
Resolv::DNS.prepend(OutsideSiteHelper::Queries)
TCPSocket.prepend(OutsideSiteHelper::Connects)
Socket.singleton_class.prepend(OutsideSiteHelper::SocketConnects)
SiteCredential.singleton_class.prepend(OutsideSiteHelper::Credentials)
