# A stand-in for fourier-sampling's creator-link door, for CreatorTimedLinks:
# it records every request (method, url, options, headers) and answers from a
# queue, so the real body building, parsing and refusals run with no network.
module TimedLinksHelper
  BASE = "http://sampling-door:5181"
  KEY = "test-creator-key"

  class FakeSamplingHttp
    attr_reader :calls

    def initialize
      @calls = []
      @answers = []
      @headers = {}
    end

    # Queue an answer: a Hash/Array becomes JSON, a String is sent as is.
    def answer(body, status: 200)
      body = body.to_json unless body.is_a?(String)
      @answers << HTTP::Response.new(status: status, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" })
      self
    end

    def timeout(*) = self
    def no_follow = self

    def headers(given)
      @headers = @headers.merge(given.transform_keys(&:to_s))
      self
    end

    %i[get post delete].each do |verb|
      define_method(verb) do |url, **options|
        @calls << { method: verb, url: url, options: options, headers: @headers.dup }
        @answers.shift or raise "FakeSamplingHttp: no answer queued for #{verb.upcase} #{url}"
      end
    end
  end

  def link_row(hash: "a" * 32, title: "October", created: Time.zone.now, ends: 7.days.from_now, posts: 2)
    { hash: hash, path: "/p/#{hash}", url: "https://sample.example.net/p/#{hash}", title: title,
      createdAt: (created.to_f * 1000).round, expiresAt: (ends.to_f * 1000).round, post_count: posts }
  end

  def listing(links = [], max_live: 5, max_days: 30)
    { ok: true, max_live: max_live, max_days: max_days, links: links }
  end

  def timed_links(gallery, http)
    CreatorTimedLinks.new(gallery, url: BASE, key: KEY, http: http)
  end
end
