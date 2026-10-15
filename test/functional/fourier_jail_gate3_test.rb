require "test_helper"

# GATE 3 FOR POSTS on the jail door (fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md): new modes of /fourier_jail/release.json,
# no new route (ruling 2026-09-24).
#
#   A    POST {"placements": ...}  -- fourier-auth's account (gate) pushes its
#        answer for each image; GET ?placements=cursor reads the cursors.
#   R1   POST release_flagged= / banish_flagged= -- the jail panel's Flagged tab.
#   R2   GET ?quarantine=1&tag_id= -- one flagged tag's posts, a keyset page.
#   R3   the quarantine document's flagged_tags.
class FourierJailGate3Test < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  LAP = 1_792_000_000_000

  def md5 = SecureRandom.hex(16)

  # A push as fourier-auth sends one; head: and at: make its snapshot.
  # at: is epoch milliseconds, as GATE3_CONTRACTS.md sends it.
  def placements(caller = @gate, head: 100, at: 1_792_026_850_598, **fields)
    body = { stream: "live", from: 0, to: 10, mxcs: [], **fields, snapshot: { head: head, at: at }}
    post_auth fourier_jail_release_path(format: :json), caller, params: { placements: body }, as: :json
    response.parsed_body
  end

  def item(mxc, rooms: ["!a:41chan.net"], site_asset: false, uploader: "@up:41chan.net", newest: 5)
    { mxc: mxc, uploader: uploader, site_asset: site_asset, rooms: rooms, newest_ordering: newest }
  end

  # The jail panel's verdict on a flagged tag (R1).
  def verdict(key, name = "secret_(thing)", caller: @sample, **params)
    post_auth fourier_jail_release_path(format: :json), caller, params: { key => name, by: "@saber:41chan.net", note: "checked", **params }, as: :json
    CreatorVisibility.forget!
    response.parsed_body
  end

  # A page of @tag's posts (R2).
  def page(caller = @sample, **params)
    get_auth fourier_jail_release_path(format: :json), caller, params: { quarantine: 1, tag_id: @tag.id, **params }
    response.parsed_body
  end

  def rooms_of(mxc) = MatrixMedia.find_by!(mxc: mxc).room_ids.map { |id| MatrixRoom.find(id).room_id }.sort

  setup do
    @gate = create(:gold_user, name: "gate")
    @sample = create(:approver_user, name: "sample")
    @tunnel = create(:approver_user, name: "tunnel")
  end

  context "A: placements pushed by fourier-auth" do
    should "record each image's answer, interned, and say how many were applied" do
      body = placements(mxcs: [item("mxc://41chan.net/one", rooms: ["!b:41chan.net", "!a:41chan.net"]), item("mxc://41chan.net/two", site_asset: true)])

      assert_response :success
      assert_equal 2, body["applied"]
      assert_equal 0, body["stale"]
      assert_equal({ "live" => 10, "sweep" => nil, "lap_started_at" => nil }, body["cursor"])
      assert_equal %w[!a:41chan.net !b:41chan.net], rooms_of("mxc://41chan.net/one")
      media = MatrixMedia.find_by!(mxc: "mxc://41chan.net/two")
      assert media.site_asset
      assert_equal "@up:41chan.net", media.uploader
      assert_equal 100, media.snapshot_head
      assert_equal 5, media.newest_ordering
    end

    should "replace an image's rooms with a newer snapshot's, so a removal lands" do
      placements(mxcs: [item("mxc://41chan.net/m", rooms: ["!a:41chan.net", "!b:41chan.net"], site_asset: true)])
      body = placements(from: 10, to: 20, head: 101, mxcs: [item("mxc://41chan.net/m", rooms: ["!b:41chan.net"], uploader: "@new:41chan.net")])

      assert_equal 1, body["applied"]
      assert_equal %w[!b:41chan.net], rooms_of("mxc://41chan.net/m")
      assert_not MatrixMedia.find_by!(mxc: "mxc://41chan.net/m").site_asset
      assert_equal "@new:41chan.net", MatrixMedia.find_by!(mxc: "mxc://41chan.net/m").uploader

      placements(from: 20, to: 30, head: 102, mxcs: [item("mxc://41chan.net/m", rooms: [])])
      assert_equal [], rooms_of("mxc://41chan.net/m")
    end

    should "ignore an older or equal snapshot as stale" do
      placements(head: 200, mxcs: [item("mxc://41chan.net/m", rooms: ["!a:41chan.net"])])
      older = placements(stream: "sweep", lap: LAP, head: 150, mxcs: [item("mxc://41chan.net/m", rooms: ["!z:41chan.net"])])
      same = placements(stream: "sweep", lap: LAP, head: 200, mxcs: [item("mxc://41chan.net/m", rooms: ["!z:41chan.net"])])

      assert_equal [0, 1], [older["applied"], older["stale"]]
      assert_equal [0, 1], [same["applied"], same["stale"]]
      assert_equal %w[!a:41chan.net], rooms_of("mxc://41chan.net/m")
    end

    should "order snapshots by head, then by time" do
      placements(head: 200, at: "2026-10-15T01:00:00Z", mxcs: [item("mxc://41chan.net/m", rooms: ["!a:41chan.net"])])
      body = placements(head: 200, at: "2026-10-15T01:00:05Z", mxcs: [item("mxc://41chan.net/m", rooms: ["!b:41chan.net"])])
      assert_equal 1, body["applied"]
      assert_equal %w[!b:41chan.net], rooms_of("mxc://41chan.net/m")
    end

    should "move the cursor only upward" do
      placements(to: 50)
      body = placements(from: 10, to: 20)
      assert_equal 50, body["cursor"]["live"]
      assert_equal 50, MatrixPlacementCursor.find_by!(stream: "live").position
    end

    # The sweep starts at the tail of Synapse's history (NEGATIVE
    # stream_ordering), so no position marks a new lap: every sweep page
    # carries "lap", the lap's start in epoch ms (GATE3_CONTRACTS.md, dcfb4de).
    # A NEWER lap sets the cursor; the same lap only advances; an older lap
    # is stale -- so a reader restarted mid-lap finishes the lap it was in.
    should "start a new sweep lap when the push's lap is newer, advance within a lap, ignore an older one" do
      first = placements(stream: "sweep", lap: LAP, from: -210_145, to: -200_000)
      assert_equal({ "live" => nil, "sweep" => -200_000, "lap_started_at" => LAP }, first["cursor"])

      assert_equal 90, placements(stream: "sweep", lap: LAP, from: -200_000, to: 90)["cursor"]["sweep"]
      # Same lap, a late lower page: never down.
      assert_equal 90, placements(stream: "sweep", lap: LAP, from: -210_145, to: -205_000)["cursor"]["sweep"]
      # An older lap: stale, nothing moves.
      stale = placements(stream: "sweep", lap: LAP - 86_400_000, from: -210_145, to: -200_000)["cursor"]
      assert_equal [90, LAP], [stale["sweep"], stale["lap_started_at"]]
      # A newer lap: SET to its `to`, the one way down.
      again = placements(stream: "sweep", lap: LAP + 86_400_000, from: -210_145, to: -200_000)["cursor"]
      assert_equal [-200_000, LAP + 86_400_000], [again["sweep"], again["lap_started_at"]]
    end

    should "refuse a sweep page without its lap, and a lap on the live stream, naming the fix" do
      placements(stream: "sweep", from: -10, to: 10)
      assert_response 422
      assert_match(/lap must be the sweep lap/, response.parsed_body.to_s)
      placements(stream: "live", lap: LAP, from: 0, to: 10)
      assert_response 422
      assert_match(/sweep pages only/, response.parsed_body.to_s)
    end

    should "isolate a bad item: count it, name it, apply the rest and advance the cursor" do
      body = placements(to: 30, mxcs: [
        item("https://not-an-mxc/x"),
        item("mxc://41chan.net/good"),
        { mxc: "mxc://41chan.net/bad-rooms", uploader: "@u:41chan.net", site_asset: false, rooms: ["#alias:41chan.net"] },
        "not an object",
      ])

      assert_response :success
      assert_equal 1, body["applied"]
      assert_equal 3, body["rejected"]
      assert_equal ["https://not-an-mxc/x", "mxc://41chan.net/bad-rooms", nil], body["rejections"].pluck("mxc")
      assert body["rejections"].all? { |r| r["reason"].present? }
      assert_equal 30, body["cursor"]["live"]
      assert MatrixMedia.exists?(mxc: "mxc://41chan.net/good")
    end

    should "isolate an item the database refuses" do
      MatrixPlacements.any_instance.stubs(:upsert!).with { |row, *| row[:mxc] == "mxc://41chan.net/boom" }.raises(ActiveRecord::StatementInvalid, "boom")
      MatrixPlacements.any_instance.stubs(:upsert!).with { |row, *| row[:mxc] != "mxc://41chan.net/boom" }.returns(true)
      body = placements(mxcs: [item("mxc://41chan.net/boom"), item("mxc://41chan.net/fine")])
      assert_equal [1, 1], [body["applied"], body["rejected"]]
      assert_match(/StatementInvalid/, body["rejections"].sole["reason"])
    end

    should "count what fourier-auth skipped" do
      assert_equal 2, placements(skipped: [{ event: "$a" }, { event: "$b" }])["skipped"]
    end

    should "recompute every post mapped to an image it writes" do
      post = create(:post, md5: md5, source: "mxc://41chan.net/posted")
      PostMxc.create!(post: create(:post, md5: md5, source: "https://example.com/x.png"), mxc: "mxc://41chan.net/alias-of-booru", source: PostMxc::ALIAS)
      PostMxc.create!(post: post, mxc: "mxc://41chan.net/alias", source: PostMxc::ALIAS)
      assert_equal [], post.reload.room_ids

      placements(mxcs: [item("mxc://41chan.net/posted", rooms: ["!a:41chan.net"]), item("mxc://41chan.net/alias", rooms: ["!b:41chan.net"], site_asset: true)])

      assert_equal [-1, MatrixRoom.find_by!(room_id: "!a:41chan.net").id, MatrixRoom.find_by!(room_id: "!b:41chan.net").id].sort, post.reload.room_ids
    end

    should "refuse a malformed push as a whole, naming what to send" do
      post_auth fourier_jail_release_path(format: :json), @gate, params: { placements: { stream: "fast", to: 1, snapshot: { head: 1, at: "2026-10-15T00:00:00Z" }, mxcs: [] }}, as: :json
      assert_response 422
      assert_match(/stream must be one of live, sweep/, response.parsed_body["error"])

      post_auth fourier_jail_release_path(format: :json), @gate, params: { placements: { stream: "live", to: 1, mxcs: [] }}, as: :json
      assert_response 422
      assert_match(/snapshot must be/, response.parsed_body["error"])
      assert_not MatrixPlacementCursor.exists?
    end

    should "refuse every account but gate, naming the setting" do
      [@sample, @tunnel, create(:admin_user), create(:approver_user)].each do |caller|
        placements(caller, mxcs: [item("mxc://41chan.net/m")])
        assert_response 403
        assert_match(/fourier_quarantine_reader_names/, response.body)
      end
      assert_not MatrixMedia.exists?
    end

    should "refuse gate at Member level" do
      @gate.update!(level: User::Levels::MEMBER)
      placements(mxcs: [item("mxc://41chan.net/m")])
      assert_response 403
      assert_match(/above Member/, response.body)
    end

    should "answer the cursors to gate alone" do
      placements(to: 7)
      get_auth fourier_jail_release_path(format: :json), @gate, params: { placements: "cursor" }
      assert_response :success
      assert_equal({ "cursor" => { "live" => 7, "sweep" => nil, "lap_started_at" => nil }}, response.parsed_body)

      get_auth fourier_jail_release_path(format: :json), @sample, params: { placements: "cursor" }
      assert_response 403
    end

    should "leave the release and the jail feed as they were" do
      get_auth fourier_jail_release_path(format: :json), @sample
      assert_response :success
      assert response.parsed_body.key?("events")
      post_auth fourier_jail_release_path(format: :json), @sample, params: { md5: "nope" }
      assert_response 422
      assert_match(/md5 must be 32 hex/, response.parsed_body["reason"])
    end
  end

  context "R1: release or banish a flagged tag from the jail panel" do
    setup do
      flag_tags!("secret_(thing)")
    end

    should "release it, naming the panel user in the mod log" do
      body = verdict(:release_flagged)
      assert_response :success
      assert_equal({ "released_flagged" => true, "tag" => "secret_(thing)" }, body)
      assert_not TagQuarantine.flagged_names.include?("secret_(thing)")
      log = ModAction.where(category: :tag_flag_release).sole
      assert_equal @sample, log.creator
      assert_includes log.description, "@saber:41chan.net"
      assert_includes log.description, "checked"
    end

    should "banish it, naming the panel user and never the tag in the mod log" do
      body = verdict(:banish_flagged)
      assert_response :success
      assert_equal({ "banished_flagged" => true, "tag" => "secret_(thing)" }, body)
      assert TagBanishment.banished?("secret_(thing)")
      log = ModAction.where(category: :tag_banish).sole
      assert_equal @sample, log.creator
      assert_includes log.description, "@saber:41chan.net"
      assert_not_includes log.description, "secret_(thing)"
    end

    should "answer a name that is not flagged 200 false" do
      assert_equal false, verdict(:release_flagged, "never_flagged")["released_flagged"]
      assert_response :success
      assert_match(/not flagged/, response.parsed_body["reason"])

      banish_tags!("already_gone")
      assert_equal false, verdict(:banish_flagged, "already_gone")["banished_flagged"]
      assert_match(/not flagged/, response.parsed_body["reason"])
      assert TagBanishment.banished?("already_gone")
    end

    should "require the panel user who pressed it" do
      verdict(:release_flagged, by: "")
      assert_response 422
      assert_match(/by must name the jail panel user/, response.parsed_body["reason"])
      assert TagQuarantine.flagged_names.include?("secret_(thing)")
    end

    should "refuse every caller but the jail panel's account" do
      [@gate, @tunnel, create(:admin_user)].each do |caller|
        verdict(:release_flagged, caller: caller)
        assert_response 403
      end
      assert TagQuarantine.flagged_names.include?("secret_(thing)")
    end
  end

  context "R2: one flagged tag's posts" do
    setup do
      flag_tags!("secret_(thing)")
      banish_tags!("gore")
      @tag = Tag.find_by_name("secret_(thing)")
      uploader = create(:user, name: "uploader_one")
      @posts = 3.times.map { |i| create(:post, md5: md5, uploader: uploader, tag_string: "landscape secret_(thing)", source: i.zero? ? "mxc://41chan.net/p#{i}" : "https://example.com/#{i}.png", rating: "s") }
      @other = create(:post, md5: md5, uploader: uploader, tag_string: "landscape")
    end

    should "list the posts carrying the tag, oldest first, with what the panel draws" do
      body = page(limit: 25)
      assert_response :success
      assert_equal({ "id" => @tag.id, "name" => "secret_(thing)", "post_count" => @tag.reload.post_count }, body["tag"])
      assert_equal TagQuarantine.names_generation, body["generation"]
      assert_equal @posts.map(&:id), body["posts"].pluck("id")
      first = body["posts"].first
      assert_equal({ "id" => @posts[0].id, "md5" => @posts[0].md5, "mxc" => "mxc://41chan.net/p0", "file_ext" => @posts[0].file_ext, "rating" => "s",
                     "uploader" => "uploader_one", "created_at" => @posts[0].created_at.iso8601, "deleted" => false, "jailed" => false, "hold" => false,
                     "flagged" => ["secret_(thing)"], "banished" => false }, first)
      assert_nil body["posts"].second["mxc"]
      assert_nil body["next_after"]
    end

    should "page by post id" do
      stub_const(FourierJailController, :TAG_POST_LIMITS, [1, 25]) do
        first = page(limit: 1)
        assert_equal [@posts[0].id], first["posts"].pluck("id")
        assert_equal @posts[0].id, first["next_after"]
        second = page(limit: 1, after: first["next_after"])
        assert_equal [@posts[1].id], second["posts"].pluck("id")
        third = page(limit: 1, after: @posts[2].id)
        assert_equal [], third["posts"]
        assert_nil third["next_after"]
      end
    end

    should "refuse a page size outside 25, 50, 100, 200" do
      page(limit: 1000)
      assert_response 422
      assert_match(/limit must be one of 25, 50, 100, 200/, response.parsed_body["error"])
    end

    should "answer an unknown tag in the body" do
      get_auth fourier_jail_release_path(format: :json), @sample, params: { quarantine: 1, tag_id: 0 }
      assert_response :success
      assert_nil response.parsed_body["tag"]
      assert_match(/no tag/, response.parsed_body["reason"])
    end

    should "be the jail panel's alone" do
      page(@gate)
      assert_response 403
      page(@tunnel)
      assert_response 403
    end
  end

  context "R3: the quarantine document's flagged tags" do
    should "name each flagged tag with its id, to the pipeline alone" do
      flag_tags!("secret_(thing)", "another_(thing)")
      get_auth fourier_jail_release_path(format: :json), @sample, params: { quarantine: 1 }
      expected = %w[another_(thing) secret_(thing)].map { |name| { "id" => Tag.find_by_name(name).id, "name" => name } }
      assert_equal expected, response.parsed_body["flagged_tags"]

      get_auth fourier_jail_release_path(format: :json), @gate, params: { quarantine: 1 }
      assert_nil response.parsed_body["flagged_tags"]
    end
  end
end
