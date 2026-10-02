require "test_helper"

# A captcha that cannot be CHECKED is not a passed captcha. Turnstile's
# answer is fetched from Cloudflare; when that request fails -- a timeout, no
# connection -- the client returns no body, and verify_request! read the
# missing "success" as not-false and let the request through. Found when the
# fork gate's captcha login test hung on the network for 414 seconds and then
# logged the user in (2026-10-02).
class CaptchaServiceTest < ActiveSupport::TestCase
  def captcha(status:, body: "")
    http = Danbooru::Http.new
    response = HTTP::Response.new(status: status, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" })
    http.stubs(:request).returns(response)
    CaptchaService.new(site_key: "site", secret_key: "secret", http: http)
  end

  def request_with_token
    ActionDispatch::TestRequest.create.tap { |r| r.params["cf-turnstile-response"] = "token" }
  end

  context "verifying a request" do
    should "refuse when Cloudflare cannot be reached" do
      assert_not captcha(status: 597).verify_request(request_with_token), "a timed-out check passed"
      assert_not captcha(status: 598).verify_request(request_with_token), "an unconnectable check passed"
    end

    should "refuse when Cloudflare answers with an error page" do
      assert_not captcha(status: 500, body: "oops").verify_request(request_with_token)
    end

    should "refuse when Cloudflare says the token failed" do
      assert_not captcha(status: 200, body: { "success" => false, "error-codes" => ["invalid-input-response"] }.to_json).verify_request(request_with_token)
    end

    should "pass when Cloudflare says the token succeeded" do
      assert captcha(status: 200, body: { "success" => true }.to_json).verify_request(request_with_token)
    end
  end
end
