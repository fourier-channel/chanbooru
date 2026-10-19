require "test_helper"

# Fork: a bulk update request tells each viewer whether they may approve it
# and whether they may reject it (can_approve, can_reject), asked of the same
# policy methods the approve and destroy actions authorize against. The
# Technetium card renders its Approve and Reject buttons from these alone
# (technetium-81, 2026-10-19), so a flag that disagrees with its action is
# a button that lies.
class FourierBurViewerFlagsTest < ActionDispatch::IntegrationTest
  setup do
    @member = create(:user)
    @requester = create(:user)
    @builder = create(:builder_user)
    @mod = create(:mod_user)
    @admin = create(:admin_user)
    @approver = create(:approver_user)
    # Neru-chan's account: a posting bot (fourier_posting_bot_names), an
    # Approver by level as on production.
    @tunnel = create(:approver_user, name: "tunnel")

    create(:tag, name: "artist1a", category: Tag.categories.artist, post_count: 10)
    # A small artist alias: a Builder's to approve by level.
    @small = "create alias artist1a -> artist1b"
    # A mass update: an Admin's to approve.
    @large = "mass update aaa -> bbb"
  end

  def bur(script = @large, status: "pending", user: @requester)
    create(:bulk_update_request, user: user, script: script, status: status)
  end

  def flags_of(bur, viewer, **params)
    if viewer
      get_auth bulk_update_request_path(bur, format: :json, **params), viewer
    else
      get bulk_update_request_path(bur, format: :json, **params)
    end
    assert_response :success
    response.parsed_body.slice("can_approve", "can_reject")
  end

  def as_viewer(method, path, viewer)
    viewer ? send(:"#{method}_auth", path, viewer) : send(method, path)
  end

  def basic_auth(user, key)
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user.name, key.key) }
  end

  # 6a
  should "tell an admin both flags on a pending request" do
    assert_equal({ "can_approve" => true, "can_reject" => true }, flags_of(bur, @admin))
  end

  # 6b
  should "tell the requester they may reject but not approve, and another member neither" do
    request = bur
    assert_equal({ "can_approve" => false, "can_reject" => true }, flags_of(request, @requester))
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(request, @member))
  end

  # 6c
  should "follow the script's approval level, not the viewer's role" do
    assert_equal(true, flags_of(bur(@small), @builder)["can_approve"])
    assert_equal(false, flags_of(bur("#{@small}\n#{@large}"), @builder)["can_approve"])
    assert_equal(true, flags_of(bur("#{@small}\n#{@large}"), @admin)["can_approve"])
    assert_equal(true, flags_of(bur(@small), @mod)["can_approve"])
  end

  # 6d -- a rejected request stays approvable, as upstream (operator,
  # 2026-10-19); a failed one too. Neither can be rejected again.
  should "follow the request's status" do
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(bur(status: "processing"), @admin))
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(bur(status: "approved"), @admin))
    assert_equal({ "can_approve" => true, "can_reject" => false }, flags_of(bur(status: "rejected"), @admin))
    assert_equal({ "can_approve" => true, "can_reject" => false }, flags_of(bur(status: "failed"), @admin))
    # A run that skipped posts can be approved again, as a failed one.
    assert_equal({ "can_approve" => true, "can_reject" => false }, flags_of(bur(status: "partial"), @admin))
  end

  # 6e
  should "tell signed-out, banned and restricted viewers neither" do
    request = bur
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(request, nil))
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(request, create(:banned_user)))
    assert_equal({ "can_approve" => false, "can_reject" => false }, flags_of(request, create(:restricted_user)))
  end

  should "answer a signed-out visitor 404 with no flags where the site is members-only" do
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    get bulk_update_request_path(bur, format: :json)

    assert_response 404
    assert_not(response.parsed_body.key?("can_approve"))
    assert_not(response.parsed_body.key?("can_reject"))
  end

  # 6f
  should "compute the flags for the account behind an API key" do
    key = create(:api_key, user: @approver)
    request = bur(user: @approver)
    get bulk_update_request_path(request, format: :json), headers: basic_auth(@approver, key)

    assert_response :success
    assert_equal({ "can_approve" => false, "can_reject" => true }, response.parsed_body.slice("can_approve", "can_reject"))
  end

  # A posting bot files requests for people and approves none (operator,
  # 2026-10-19), though its level clears a small artist alias. The control
  # is an Approver of the same level who is not a bot.
  should "never let a posting bot approve, even a request its level clears" do
    key = create(:api_key, user: @tunnel)
    request = bur(@small)
    assert_equal(true, flags_of(request, @approver)["can_approve"])

    get bulk_update_request_path(request, format: :json), headers: basic_auth(@tunnel, key)
    assert_response :success
    assert_equal(false, response.parsed_body["can_approve"])

    post approve_bulk_update_request_path(request, format: :json), headers: basic_auth(@tunnel, key)
    assert_response 403
    assert_equal("pending", request.reload.status)
    assert_nil(request.approver_id)
  end

  should "carry the flags on create.json, approve.json and index.json, and honour ?only=" do
    post_auth bulk_update_requests_path(format: :json), @requester, params: { bulk_update_request: { script: @large, title: "t", reason: "r" }}
    assert_response 201
    assert_equal({ "can_approve" => false, "can_reject" => true }, response.parsed_body.slice("can_approve", "can_reject"))
    request = BulkUpdateRequest.find(response.parsed_body["id"])

    get_auth bulk_update_requests_path(format: :json), @admin
    assert_response :success
    assert_equal({ "can_approve" => true, "can_reject" => true }, response.parsed_body.find { |row| row["id"] == request.id }.slice("can_approve", "can_reject"))

    get_auth bulk_update_request_path(request, format: :json, only: "id,status,can_approve"), @admin
    assert_equal({ "id" => request.id, "status" => "pending", "can_approve" => true }, response.parsed_body)

    post_auth approve_bulk_update_request_path(request, format: :json), @admin
    assert_response 201
    assert_equal({ "status" => "processing", "can_approve" => false, "can_reject" => false }, response.parsed_body.slice("status", "can_approve", "can_reject"))
  end

  # 6g -- the one-source-of-truth test. For every viewer, status and script,
  # a flag that says no is a 403 that changes nothing, and a flag that says
  # yes is an action the policy lets through.
  should "agree with the action it describes, for every viewer, status and script" do
    viewers = { "signed out" => nil, "member" => @member, "requester" => @requester, "banned" => create(:banned_user),
                "builder" => @builder, "admin" => @admin, "posting bot" => @tunnel }

    viewers.each do |label, viewer|
      %w[pending rejected failed partial approved].each do |status|
        [@small, @large].each do |script|
          cell = "#{label} / #{status} / #{script}"
          approving = bur(script, status: status)
          flags = flags_of(approving, viewer)

          as_viewer(:post, approve_bulk_update_request_path(approving, format: :json), viewer)
          if flags["can_approve"]
            assert_response 201, cell
          else
            assert_response 403, cell
            assert_equal(status, approving.reload.status, cell)
          end

          rejecting = bur(script, status: status)
          as_viewer(:delete, bulk_update_request_path(rejecting, format: :json), viewer)
          if flags["can_reject"]
            assert_response 204, cell
            assert_equal("rejected", rejecting.reload.status, cell)
          else
            assert_response 403, cell
            assert_equal(status, rejecting.reload.status, cell)
          end
        end
      end
    end
  end
end
