require "test_helper"

# The decision is made from the provider's framing headers. These assert the
# mapping directly, because the alternative -- letting a component test reach a
# real identity provider -- is a test that fails when someone else's server is
# slow.
class MatrixSigninFrameabilityTest < ActiveSupport::TestCase
  BOORU = "https://booru.example.com".freeze
  PROVIDER = "https://auth.example.com/authorize".freeze

  def verdict(xfo: nil, csp: nil, url: PROVIDER, embedder: BOORU)
    headers = {}
    headers["X-Frame-Options"] = xfo if xfo
    headers["Content-Security-Policy"] = csp if csp
    response = Struct.new(:headers).new(headers)

    http = Object.new
    http.define_singleton_method(:no_follow) { self }
    http.define_singleton_method(:head) { |_| response }

    MatrixSigninFrameability.send(:permits_framing?, http, url, embedder: embedder)
  end

  context "MatrixSigninFrameability" do
    should "refuse when the provider sends DENY" do
      assert_equal(false, verdict(xfo: "DENY"))
    end

    # The case this whole class exists for: SAMEORIGIN reads as permissive until
    # you notice the booru and the provider are different hosts.
    should "refuse SAMEORIGIN from a different origin" do
      assert_equal(false, verdict(xfo: "SAMEORIGIN"))
    end

    should "allow SAMEORIGIN when it really is the same origin" do
      assert_equal(true, verdict(xfo: "SAMEORIGIN", url: "#{BOORU}/fourier/login"))
    end

    should "allow when the provider sends no framing header at all" do
      assert_equal(true, verdict)
    end

    # frame-ancestors supersedes X-Frame-Options where both are present.
    should "prefer frame-ancestors over X-Frame-Options" do
      assert_equal(true, verdict(xfo: "DENY", csp: "default-src 'self'; frame-ancestors #{BOORU}"))
      assert_equal(false, verdict(xfo: "", csp: "frame-ancestors 'none'"))
    end

    should "handle frame-ancestors wildcards and hosts" do
      assert_equal(true, verdict(csp: "frame-ancestors *"))
      assert_equal(true, verdict(csp: "frame-ancestors https://booru.example.com"))
      assert_equal(false, verdict(csp: "frame-ancestors https://someone-else.example.com"))
    end

    should "be off in test so the suite never reaches the network" do
      assert_equal(:never, Danbooru.config.matrix_signin_frame_mode)
      assert_equal(false, MatrixSigninFrameability.frameable?("/fourier/login"))
    end
  end
end
