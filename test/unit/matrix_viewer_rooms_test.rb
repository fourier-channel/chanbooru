require "test_helper"

# THE VIEWER'S ROOM SET (MatrixViewerRooms): fourier-auth's rooms for the
# viewer's own session, interned, plus 0 for everyone and -1 for a verified
# viewer. Every failure is {0} -- no Matrix post shown -- and is reported.
class MatrixViewerRoomsTest < ActiveSupport::TestCase
  MXID = "@reader:41chan.net"
  URL = "http://fourier-auth:8010/verify?gate=rooms"

  setup do
    @user = create(:user)
    @a = MatrixRoom.create!(room_id: "!a:41chan.net")
    @b = MatrixRoom.create!(room_id: "!b:41chan.net")
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    CreatorVisibility.forget!
  end

  def request_for(mxid: MXID, cookie: "sess-1")
    env = {}
    env["HTTP_X_FOURIER_IDENTITY"] = mxid if mxid
    env["HTTP_COOKIE"] = "fourier_session=#{cookie}" if cookie
    ActionDispatch::TestRequest.create(env)
  end

  def response(body, status: 200)
    body = body.to_json unless body.is_a?(String)
    HTTP::Response.new(status: status, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" })
  end

  def answer(rooms, mxid: MXID)
    { mxid: mxid, rooms: rooms.sort, count: rooms.size, digest: Digest::SHA256.hexdigest(rooms.sort.join("\n")), as_of: Time.zone.now.iso8601 }
  end

  def rooms_for(user = @user, request: request_for)
    CurrentUser.set(user: user, request: request) do
      MatrixViewerRooms.ids(user)
    end
  ensure
    CreatorVisibility.forget!
  end

  # The placed grant as the request's own viewer sees it.
  def grant
    CurrentUser.set(user: @user, request: request_for) { MatrixViewerRooms.placed_grant }
  ensure
    CreatorVisibility.forget!
  end

  should "be 0, -1 and the viewer's interned rooms, dropping rooms no post was placed in" do
    Danbooru::Http.any_instance.expects(:get).with(URL).returns(response(answer(["!a:41chan.net", "!b:41chan.net", "!never:41chan.net"])))
    assert_equal [-1, 0, @a.id, @b.id].sort, rooms_for
  end

  should "forward the viewer's own fourier_session cookie" do
    Danbooru::Http.any_instance.expects(:cookies).with("fourier_session" => "sess-1").returns(Danbooru::Http.new)
    Danbooru::Http.any_instance.stubs(:get).with(URL).returns(response(answer(["!a:41chan.net"])))
    rooms_for
  end

  should "be 0 and -1 for a verified viewer in no room" do
    Danbooru::Http.any_instance.stubs(:get).returns(response(answer([])))
    assert_equal [-1, 0], rooms_for
  end

  should "ask fourier-auth once while the answer is cached" do
    Danbooru::Http.any_instance.expects(:get).once.returns(response(answer(["!a:41chan.net"])))
    2.times { assert_equal [-1, 0, @a.id], rooms_for }
  end

  should "cache a viewer with rooms about 45 s and one without about 10 s" do
    Danbooru::Http.any_instance.stubs(:get).returns(response(answer(["!a:41chan.net"])))
    @cache.expects(:write).with(anything, [-1, 0, @a.id], expires_in: 45.seconds)
    rooms_for

    Danbooru::Http.any_instance.stubs(:get).returns(response(answer([], mxid: "@empty:41chan.net")))
    @cache.expects(:write).with(anything, [-1, 0], expires_in: 10.seconds)
    rooms_for(request: request_for(mxid: "@empty:41chan.net"))
  end

  context "failing closed" do
    setup do
      @reports = []
      @subscriber = ActiveSupport::Notifications.subscribe("gate3.viewer_rooms_failed") { |*, payload| @reports << payload }
    end

    teardown do
      ActiveSupport::Notifications.unsubscribe(@subscriber)
    end

    should "be {0}, without asking, for a viewer with no verified identity" do
      Danbooru::Http.any_instance.expects(:get).never
      assert_equal [0], rooms_for(request: request_for(mxid: nil))
    end

    should "be {0} for a viewer the request is not about" do
      Danbooru::Http.any_instance.expects(:get).never
      other = create(:user)
      ids = CurrentUser.set(user: @user, request: request_for) { MatrixViewerRooms.ids(other) }
      assert_equal [0], ids
    end

    should "be {0} when the answer names someone else" do
      Danbooru::Http.any_instance.stubs(:get).returns(response(answer(["!a:41chan.net"], mxid: "@someone:41chan.net")))
      assert_equal [0], rooms_for
      assert_match(/not for #{Regexp.escape(MXID)}/, @reports.sole[:reason])
    end

    {
      401 => /signs in again/,
      503 => /could not read Synapse/,
      597 => /timed out/,
      598 => /could not reach/,
      500 => /answered HTTP 500/,
    }.each do |status, remedy|
      should "be {0} on #{status}, naming what to do" do
        Danbooru::Http.any_instance.stubs(:get).returns(response("{}", status: status))
        assert_equal [0], rooms_for
        assert_match(remedy, @reports.sole[:reason])
      end
    end

    should "never cache a failure: the next request asks fourier-auth again" do
      Danbooru::Http.any_instance.expects(:get).twice.returns(response("{}", status: 503))
      assert_equal [0], rooms_for
      assert_equal [0], rooms_for(request: request_for)
    end

    should "be {0} for a body that is not the documented shape" do
      ["not json", "[]", { mxid: MXID, rooms: "!a:41chan.net" }.to_json, { mxid: MXID, rooms: ["#alias:41chan.net"] }.to_json,
       { mxid: MXID, rooms: ["!a:41chan.net"], count: 2 }.to_json].each do |body|
        @cache.clear
        Danbooru::Http.any_instance.stubs(:get).returns(response(body))
        assert_equal [0], rooms_for, body
      end
      assert_equal 5, @reports.size
    end

    should "be {0} when the request carries an identity but no cookie" do
      Danbooru::Http.any_instance.expects(:get).never
      assert_equal [0], rooms_for(request: request_for(cookie: nil))
      assert_match(/no fourier_session cookie/, @reports.sole[:reason])
    end
  end

  context "placed_grant" do
    setup do
      @shown = create(:post, tag_string: "night").tap { |post| post.update_columns(room_ids: [@a.id]) } # rubocop:disable Rails/SkipsModelValidations
      @gated = create(:post, tag_string: "night child").tap { |post| post.update_columns(room_ids: [@a.id]) } # rubocop:disable Rails/SkipsModelValidations
    end

    should "hold only the placed posts a signed-out viewer may see, Gate 3 aside" do
      MembersOnly.remember_placed([@shown.id, @gated.id])
      assert_equal Set[@shown.id], grant
    end

    should "leave out a placed post whose md5 the signed-out md5 ask withholds: banned, or taken down" do
      banned = create(:post, tag_string: "night", is_banned: true).tap { |post| post.update_columns(room_ids: [@a.id]) } # rubocop:disable Rails/SkipsModelValidations
      taken_down = create(:post, tag_string: "night").tap { |post| post.update_columns(room_ids: [@a.id], bit_flags: 4) } # rubocop:disable Rails/SkipsModelValidations
      assert(taken_down.reload.is_taken_down?, "fixture: taken down")
      MembersOnly.remember_placed([@shown.id, banned.id, taken_down.id])
      assert_equal Set[@shown.id], grant
    end

    should "be empty with no request" do
      MembersOnly.remember_placed([@shown.id])
      assert_equal Set.new, MatrixViewerRooms.placed_grant(request: nil)
    end

    should "ask about a new placement at once, and keep a check for PLACED_GRANT_CHECKED" do
      MembersOnly.remember_placed([@shown.id])
      assert_equal Set[@shown.id], grant

      other = create(:post, tag_string: "night").tap { |post| post.update_columns(room_ids: [@b.id]) } # rubocop:disable Rails/SkipsModelValidations
      MembersOnly.remember_placed([other.id])
      assert_equal Set[@shown.id, other.id], grant

      other.update_columns(tag_string: "night child") # rubocop:disable Rails/SkipsModelValidations
      assert_equal Set[@shown.id, other.id], grant, "a check is kept while fresh"
      travel(MatrixViewerRooms::PLACED_GRANT_CHECKED + 1.second) do
        assert_equal Set[@shown.id], grant
      end
    end
  end

  context "enforced_for?" do
    should "be off while the switch is off" do
      assert_not MatrixViewerRooms.enforced_for?(@user)
    end

    should "spare the pipeline and nobody else, admins included" do
      Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
      assert MatrixViewerRooms.enforced_for?(@user)
      assert MatrixViewerRooms.enforced_for?(create(:admin_user))
      assert MatrixViewerRooms.enforced_for?(User.anonymous)
      assert_not MatrixViewerRooms.enforced_for?(User.system)
      assert_not MatrixViewerRooms.enforced_for?(create(:builder_user, name: "tunnel"))
    end
  end
end
