require "test_helper"

class ErrorsControllerTest < ActionDispatch::IntegrationTest
  context "The errors controller" do
    should "render a card for every status it knows" do
      ErrorArt.statuses.each do |status|
        get error_art_path(status: status, format: :svg)

        assert_response :success, "status #{status} did not render"
        assert_equal("image/svg+xml", response.media_type)
        assert_match(status.to_s, response.body)
        # Escaped, because several titles contain an apostrophe and the SVG is
        # correctly HTML-escaped on the way out.
        assert_match(ERB::Util.html_escape(ErrorArt.new(status).title), response.body)
      end
    end

    # A card for an unknown status is the whole point: the alternative is the
    # broken-image glyph this exists to replace.
    should "still render a card for a status it does not know" do
      get error_art_path(status: 599, format: :svg)

      assert_response :success
      assert_match("599", response.body)
      assert_match(ERB::Util.html_escape(ErrorArt::FALLBACK[:title]), response.body)
    end

    should "render the compact layout on request" do
      get error_art_path(status: 403, format: :svg, compact: 1)

      assert_response :success
      assert_match("403", response.body)
      assert_match("Not Authorized!", response.body)

      # Compact drops the sentence from the DRAWING, because it is unreadable at
      # the size compact exists for -- but keeps it in the aria-label, so a
      # screen reader still gets the explanation a sighted reader loses.
      drawn = response.body.scan(%r{<text[^>]*>(.*?)</text>}m).flatten.join(" ")
      assert_no_match(/have permission/, drawn)
      assert_match(/have permission/, response.body[/aria-label="[^"]*"/].to_s)
    end

    should "draw the explanation in the full layout" do
      get error_art_path(status: 403, format: :svg)

      drawn = response.body.scan(%r{<text[^>]*>(.*?)</text>}m).flatten.join(" ")
      assert_match(/have permission/, drawn)
    end

    # Requested exactly when something is already going wrong; the failure path
    # should not also be the expensive path.
    should "be cacheable" do
      get error_art_path(status: 404, format: :svg)

      assert_match(/max-age/, response.headers["Cache-Control"].to_s)
      assert_match(/public/, response.headers["Cache-Control"].to_s)
    end

    should "be reachable without an account" do
      get error_art_path(status: 403, format: :svg)

      assert_response :success
    end
  end

  context "ErrorArt" do
    should "cover every status this application actually returns" do
      # Sourced from ApplicationController's rescue_from table, plus 502/504
      # which come from the proxy rather than from Rails.
      returned_by_app = [400, 401, 403, 404, 405, 406, 410, 422, 429, 451, 500, 501, 503]
      missing = returned_by_app - ErrorArt.statuses

      assert_empty(missing, "no error card for: #{missing.join(", ")}")
    end
  end
end
