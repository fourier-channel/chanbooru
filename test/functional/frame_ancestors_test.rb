# frozen_string_literal: true

require "test_helper"

# The booru is framed by Technetium (operator, 2026-09-06). Rails' default
# X-Frame-Options: SAMEORIGIN would refuse that, so it is replaced by a CSP
# frame-ancestors directive naming exactly the allowed origins.
class FrameAncestorsTest < ActionDispatch::IntegrationTest
  context "any page" do
    should "allow framing by itself and by every configured origin, via CSP" do
      # The header is built ONCE at boot from default_headers, so this reads
      # what the running configuration declares rather than stubbing a value
      # the header could not have picked up.
      get root_path
      csp = response.headers["Content-Security-Policy"]
      assert_not_nil csp
      assert_match(/frame-ancestors 'self'/, csp)
      Danbooru.config.frame_ancestor_origins.each do |origin|
        assert_includes csp, origin
      end
    end

    should "not send X-Frame-Options, which cannot name a second origin" do
      get root_path
      assert_nil response.headers["X-Frame-Options"]
    end
  end
end
