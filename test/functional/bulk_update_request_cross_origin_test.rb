require "test_helper"

# Fork: the wire contract the Technetium BUR card uses from
# https://tc.41chan.net and https://build.tc.41chan.net, pinned with forgery
# protection ON (the test env turns it off). An admin's browser session
# approves and rejects cross-origin: credentialed CORS is Caddy's (an Origin
# matcher echoing those two origins; Rails stamps only `*`), and every write
# rides a CORS-simple POST -- a form body carrying the token, with _method
# for a DELETE -- because a preflight is refused at the edge. Neru-chan files
# over Basic auth, which skips the token. Production runs with the forum
# retired, so the forum is switched off here too.
class BulkUpdateRequestCrossOriginTest < ActionDispatch::IntegrationTest
  TC = "https://tc.41chan.net"
  BUILD_TC = "https://build.tc.41chan.net"

  setup do
    Danbooru.config.stubs(:retired_sections).returns(%w[forum_topics forum_posts forum_post_votes forum_topic_visits])
    @admin = create(:admin_user)
    @member = create(:user)
    @bur = as(@member) { create(:bulk_update_request, user: @member, script: "create alias aaa -> bbb", reason: "because") }
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = false
  end

  # Signs in as a browser does (the login form's own token), in a fresh
  # session, and returns the token Technetium reads: the csrf-token meta of
  # /static/site_map (booruCsrf.ts).
  def sign_in_and_read_token(user)
    reset!
    get new_session_path
    post session_path, params: { authenticity_token: css_select("form input[name=authenticity_token]").first["value"], session: { name: user.name, password: user.password }}
    assert_redirected_to root_path
    get site_map_path
    css_select("meta[name=csrf-token]").first["content"]
  end

  def from(origin)
    { "Origin" => origin, "Accept" => "application/json" }
  end

  # T0: Rails takes the Origin header as it comes: production runs with
  # DANBOORU_REVERSE_PROXY=true (config/application.rb), which turns the
  # origin check off. With it on, every write from tc is a 403.
  should "run with the forgery origin check off, as production does" do
    assert_equal(false, ActionController::Base.forgery_protection_origin_check, "set DANBOORU_REVERSE_PROXY=true, as production's compose file does")
  end

  # T1, T2
  [TC, BUILD_TC].each do |origin|
    should "approve over a cookie session with the token in a form body, from #{origin}" do
      token = sign_in_and_read_token(@admin)
      post approve_bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token }, headers: from(origin)

      assert_response 201
      assert_equal([@bur.id, "processing", false, false], response.parsed_body.values_at("id", "status", "can_approve", "can_reject"))
      assert_equal(["processing", @admin.id], @bur.reload.slice(:status, :approver_id).values)
    end
  end

  # T3
  should "reject over a POST carrying _method=delete in the form body, answering 204 with no body" do
    token = sign_in_and_read_token(@admin)
    post bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token, _method: "delete" }, headers: from(TC)

    assert_response 204
    assert_equal("", response.body)
    assert_equal("rejected", @bur.reload.status)
  end

  # T4
  should "answer the same POST without _method with a 404, and change nothing" do
    token = sign_in_and_read_token(@admin)
    post bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token }, headers: from(TC)

    assert_response 404
    assert_equal("pending", @bur.reload.status)
  end

  # T5
  should "not honour a _method inside a JSON body" do
    token = sign_in_and_read_token(@admin)
    post bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token, _method: "delete" }.to_json, headers: from(TC).merge("Content-Type" => "application/json")

    assert_response 404
    assert_equal("pending", @bur.reload.status)
  end

  # T6
  should "refuse a write with no token as a 403 InvalidAuthenticityToken, never a 422, and change nothing" do
    sign_in_and_read_token(@admin)
    post approve_bulk_update_request_path(@bur, format: :json), headers: from(TC)

    assert_response 403
    assert_equal("ActionController::InvalidAuthenticityToken", response.parsed_body["error"])
    assert_equal(["pending", nil], @bur.reload.slice(:status, :approver_id).values)
  end

  # T7: a token from another session -- what a page holds after the booru
  # signed in again behind it.
  should "refuse a token minted for another session the same way" do
    other = open_session
    other.get site_map_path
    foreign = other.response.parsed_body.at_css("meta[name=csrf-token]")["content"]

    sign_in_and_read_token(@admin)
    post approve_bulk_update_request_path(@bur, format: :json), params: { authenticity_token: foreign }, headers: from(TC)

    assert_response 403
    assert_equal("ActionController::InvalidAuthenticityToken", response.parsed_body["error"])
    assert_equal("pending", @bur.reload.status)
  end

  # T8
  should "refuse a member's approval as a readable 403 naming the policy" do
    token = sign_in_and_read_token(@member)
    post approve_bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token }, headers: from(TC)

    assert_response 403
    assert_equal("Pundit::NotAuthorizedError", response.parsed_body["error"])
    assert_equal("pending", @bur.reload.status)
  end

  # T9: what the card reads.
  should "serve the card's fields on show.json" do
    sign_in_and_read_token(@member)
    get bulk_update_request_path(@bur, format: :json), headers: from(TC)

    assert_response :success
    body = response.parsed_body
    assert_equal([@bur.id, "pending", "create alias aaa -> bbb", "because"], body.values_at("id", "status", "script", "reason"))
    assert_equal([false, true, [], 0, nil, nil, nil], body.values_at("can_approve", "can_reject", "lines", "skipped_count", "failed_line", "forum_topic_id", "forum_post_id"))
    assert_not(body.key?("results"))
  end

  # T10
  should "let Neru-chan file over Basic auth with no token" do
    tunnel = create(:approver_user, name: "tunnel")
    key = create(:api_key, user: tunnel)
    reset!

    assert_difference("BulkUpdateRequest.count", 1) do
      post bulk_update_requests_path(format: :json), params: { bulk_update_request: { script: "create alias ccc -> ddd", reason: "asked in a room" }},
                                                     headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(tunnel.name, key.key) }
    end
    assert_response 201
    assert_equal([tunnel.id, "asked in a room"], BulkUpdateRequest.last.slice(:user_id, :reason).values)
  end

  # T11: credentialed CORS is Caddy's alone. A second
  # Access-Control-Allow-Origin from Rails would put two values on the wire,
  # which a browser refuses as it refuses the wildcard.
  should "stamp only Rails' own wildcard origin and never allow credentials" do
    sign_in_and_read_token(@member)
    get bulk_update_request_path(@bur, format: :json), headers: from(TC)

    assert_response :success
    assert_equal("*", response.headers["Access-Control-Allow-Origin"])
    assert_nil(response.headers["Access-Control-Allow-Credentials"])
  end

  # T12: no preflight is answered, so a native DELETE never goes cross-origin.
  should "answer OPTIONS on a request with the catch-all 404" do
    sign_in_and_read_token(@admin)
    options bulk_update_request_path(@bur, format: :json), headers: from(TC).merge("Access-Control-Request-Method" => "DELETE")

    assert_response 404
    assert_nil(response.headers["Access-Control-Allow-Methods"])
  end

  # T13: a refused approval reaches the card over the same door as a 422
  # with the sentence and each line at fault.
  should "refuse a stale approval with 422, the sentence and the line, and change nothing" do
    create(:tag_alias, antecedent_name: "bbb", consequent_name: "ccc")
    token = sign_in_and_read_token(@admin)
    post approve_bulk_update_request_path(@bur, format: :json), params: { authenticity_token: token }, headers: from(TC)

    assert_response 422
    body = response.parsed_body
    assert_equal([false, "BulkUpdateRequest::Processor::Error"], body.values_at("success", "error"))
    assert_match(/\ABUR ##{@bur.id} was not approved and is unchanged\./, body["message"])
    assert_equal([{ "line" => 1, "text" => "create alias aaa -> bbb", "reason" => "Can't create alias [[aaa]] -> [[bbb]] (bbb is already aliased to ccc)" }], body["errors"])
    assert_equal(["pending", nil], @bur.reload.slice(:status, :approver_id).values)
  end
end
