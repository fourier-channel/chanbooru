require "test_helper"

# The Manage Session bar's data plane: the token view's "Show tokens" step and
# purge's server half (operator rulings 2026-10-03), and the header markup that
# carries them.
class ModulationSessionTest < ActionDispatch::IntegrationTest
  context "The token view" do
    should "hand back exactly the session cookies this request carries, uncached" do
      user = create(:user)
      login_as(user)
      cookies[SessionObservation::FOURIER_COOKIE] = "fourier-value-1"
      cookies["some_other_cookie"] = "not-a-session"
      # The session cookie is re-encrypted on every response, so the value the
      # view must hand back is the one THIS request sent, read before it.
      sent = cookies[Danbooru.config.session_cookie_name]

      post modulation_session_tokens_path, as: :json

      assert_response :success
      assert_equal("no-store", response.headers["Cache-Control"])
      tokens = response.parsed_body["tokens"]
      names = tokens.map { |t| t["name"] }
      # The two the monitors read, in the monitors' order, and nothing else.
      assert_equal([Danbooru.config.session_cookie_name, SessionObservation::FOURIER_COOKIE], names)
      fourier = tokens.find { |t| t["name"] == SessionObservation::FOURIER_COOKIE }
      assert_equal("fourier-value-1", fourier["value"])
      # The fingerprint the card shows beside it is the monitors' own digest,
      # so "this is the token you are looking at" holds across both views.
      assert_equal(SessionObservation.digest("fourier-value-1"), fourier["digest"])
      booru = tokens.first
      assert_equal(sent, booru["value"])
    end

    should "list nothing for a cookie the browser does not hold" do
      post modulation_session_tokens_path, as: :json

      assert_response :success
      refute_includes(response.parsed_body["tokens"].map { |t| t["name"] }, SessionObservation::FOURIER_COOKIE)
    end

    should "be a POST only, so the CSRF check stands in front of it" do
      assert_routing({ method: "post", path: "/modulation/session_tokens" }, { controller: "modulation_session", action: "tokens" })
      get "/modulation/session_tokens"
      assert_response :not_found
    end
  end

  context "Purge, the server's half" do
    should "expire the gate's cookie and clear this origin's cache and storage, not its cookies" do
      cookies[SessionObservation::FOURIER_COOKIE] = "fourier-value-2"

      post modulation_purge_path

      assert_response :no_content
      assert_equal('"cache", "storage"', response.headers["Clear-Site-Data"])
      # "cookies" in Clear-Site-Data reaches the whole registrable domain and
      # would sign the viewer out of every other 41chan app.
      refute_match(/cookies/, response.headers["Clear-Site-Data"])
      assert(cookies[SessionObservation::FOURIER_COOKIE].blank?, "the gate's cookie is still set")
    end
  end

  context "The Modulation header" do
    should "carry the refresh/purge rectangle in place of the reload arrow, and the token card" do
      get posts_path, params: { preset: "modulation" }

      assert_response :success
      assert_select ".modnav-reset [data-act='hard-refresh']", count: 1
      assert_select ".modnav-reset [data-act='purge']", count: 1
      assert_select ".modnav-reset .modnav-reset-confirm[hidden]", count: 1
      assert_select ".modnav-reset-confirm", text: /irreversible action/
      assert_select ".modnav-refresh", count: 0
      assert_select "#modnav-tokens[hidden]", count: 1
      assert_select "#modnav-session-toggle [data-region='cta']", count: 1
    end
  end
end
