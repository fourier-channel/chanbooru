require "ipaddr"

# Fork. A TEST THAT NEEDS A LIVE OUTSIDE SITE NEVER BLOCKS A GATE (operator
# ruling 2026-11-21, memory outside-site-tests-are-optional-and-logged):
#
#   "a 502 error on an external site shouldn't be able to brick our
#   development. ... keeping those tests but making them optional and log that
#   failure on every run not as a failure, but as a lack of success at a task
#   that doesn't require success."
#
# chanbooru 58b933343 failed five deploy-gate runs, about 65 minutes each, on
# upstream tests that fetch httpbingo.org, pixiv and weibo, while every
# fork-owned test passed.
#
# WHAT COUNTS, decided per run from what the test was answered, never from a
# kept list. A failed test is NOT ACHIEVED when, during it, an outside site
# (a public host, not this machine or the private network) answered with:
#   - a 5xx, the site's own error; or
#   - 597, 598 or 599, Danbooru::Http's codes for no answer at all (timeout,
#     connection or DNS, other transport error).
# Our own refusals are NOT on the list, so a test of them stays a FAIL:
#   590 a certificate we rejected, 591 an address we prohibit,
#   595 a body over our limit, 596 our redirect limit.
# So are a 4xx (the site's definite answer about our request) and a 200 whose
# page we could not read (our parsing).
#
# The one 4xx that counts is a site saying, in its answer, that it refused
# this NETWORK rather than our request (operator 2026-11-22: a 4xx moves to
# not achieved only once it is confirmed not to be our fault). Each answer
# of that kind is one REFUSED_NETWORK entry, with the probe that confirmed
# it; any other 4xx, from any site, stays a FAIL. A test that reached no outside site
# stays a FAIL whatever happened: that is our own code. An answer made while a
# mocha stub stands on HTTP::Client or Danbooru::Http came from the test, not
# from a site, so a stubbed 503 never counts either.
#
# A not-achieved test is reported as a skip, so it is never counted as a pass.
# Its own line is printed on EVERY run, by NotAchievedReporter below: the count,
# then one "not achieved: <test> -- <site status> -- <reason>" line per miss,
# starting at column 0. coherence's gate lifts those lines onto its verdict, so
# a miss is never hidden behind a green summary.
module LiveSiteTestHelper
  PREFIX = "not achieved:"
  SITE_MISS = ((500..589).to_a + [597, 598, 599]).freeze

  # A site's answer refusing this network, not the request: its status and
  # the words its page says it in.
  REFUSED_NETWORK = [
    # Reddit. 2026-11-22, from vesper (host and dev container): logged-out
    # www.reddit.com/comments/<id>.json answered 403 with this page,
    # byte-identical under four user agents (the extractor's Firefox 108, a
    # current Firefox, an API-style agent, curl), while the same address got
    # 200 for the post's own page and its i.redd.it media. Reddit refuses
    # the address's logged-out JSON; nothing in our request decides it.
    { status: 403, says: "blocked by network security",
      reason: "the site's page says it blocked this network, not the request" },
  ].freeze

  Answer = Struct.new(:host, :status, :stubbed, :refused_network)
  STUBBABLE = [HTTP::Client, Danbooru::Http].freeze

  class << self
    # Every answer Danbooru::Http got during the running test. Each parallel
    # worker is its own process, so one list per process is one per test.
    def answers
      @answers ||= []
    end

    def record(url, status, refused_network = nil)
      host = Addressable::URI.parse(url.to_s).host.to_s.downcase
      answers << Answer.new(host, status.to_i, transport_stubbed?, refused_network)
    rescue Addressable::URI::InvalidURIError
      nil
    end

    # The REFUSED_NETWORK reason this answer gives, or nil. Reads the body
    # only when the request buffered it (read once, kept): a streamed body
    # read here would be gone for the caller.
    def refused_network(response, buffered:)
      return nil unless buffered
      refusal = REFUSED_NETWORK.find { |r| r[:status] == response.status.to_i && response.body.to_s.include?(r[:says]) }
      refusal && "#{refusal[:says]}: #{refusal[:reason]}"
    end

    # True while any mocha stub stands on the transport, on the class (an
    # any_instance stub) or on one instance of it.
    def transport_stubbed?
      Mocha::Mockery.instance.stubba.stubba_methods.any? do |m|
        STUBBABLE.any? { |k| m.stubba_object == k || m.stubba_object.is_a?(k) }
      end
    end

    # A public host: not a bare service name, not loopback, link-local or a
    # private range. A name that resolves to 127.0.0.1 (nip.io) is outside by
    # name, and what it is answered with decides: our 591 is not a miss.
    def outside?(host)
      return false if host.blank? || host == "localhost" || host.exclude?(".")
      ip = IPAddr.new(host)
      !(ip.private? || ip.loopback? || ip.link_local?)
    rescue IPAddr::InvalidAddressError
      true
    end

    def live
      answers.select { |a| !a.stubbed && outside?(a.host) }
    end

    def misses
      live.select { |a| SITE_MISS.include?(a.status) || a.refused_network }
    end

    def reached_outside?
      live.any?
    end
  end

  # Danbooru::Http#request is where every request is made, redirects hop by
  # hop and downloads included; it turns a transport error into a 59x answer.
  module Recorder
    def request(method, url, **options)
      response = super
      LiveSiteTestHelper.record(url, response.status, LiveSiteTestHelper.refused_network(response, buffered: options.fetch(:buffer, true)))
      response
    end
  end

  def before_setup
    LiveSiteTestHelper.answers.clear
    super
  end

  def after_teardown
    super
  ensure
    classify_live_site_miss
  end

  private

  def classify_live_site_miss
    metadata[:reached_outside_site] = true if LiveSiteTestHelper.reached_outside?
    failure = failures.find { |f| !f.is_a?(Minitest::Skip) }
    return if failure.nil?

    misses = LiveSiteTestHelper.misses
    return if misses.empty?

    sites = misses.map { |m| "#{m.host} answered #{m.status}#{" (#{m.refused_network})" if m.refused_network}" }.uniq
    sites = sites.first(3) + ["and #{sites.size - 3} more"] if sites.size > 3
    reason = failure.message.to_s.lines.map(&:strip).compact_blank.join(" ").squish.truncate(240)
    skip = Minitest::Skip.new("#{PREFIX} #{sites.join(", ")} -- #{reason}")
    skip.set_backtrace(failure.backtrace || [])
    self.failures = [skip]
  end

  # Prints, after every run, how many tests reached an outside site and each
  # one that was not achieved. Runs in the parent process: what a worker knew
  # arrives on the result, as its skip message and its metadata.
  class NotAchievedReporter < Minitest::Reporters::BaseReporter
    def report
      super
      reached = tests.select { |t| t.metadata? && t.metadata[:reached_outside_site] }
      missed = tests.select { |t| t.skipped? && t.failure.message.to_s.start_with?(PREFIX) }
      io.puts
      io.puts "live outside sites: #{reached.size} test(s) reached one; #{missed.size} not achieved " \
              "(an outside site missed: not a failure, not a pass; operator ruling 2026-11-21)"
      missed.each do |t|
        io.puts "#{PREFIX} #{t.klass}##{t.name.strip} -- #{t.failure.message.to_s.delete_prefix(PREFIX).strip}"
      end
    end
  end
end

Danbooru::Http.prepend(LiveSiteTestHelper::Recorder)
