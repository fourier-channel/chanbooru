require "test_helper"

# GATE 3 FOR POSTS (fourier-basis docs/design/GATE3_MATRIX_POSTS.md, operator
# rulings 2026-10-14/15): a Matrix post is visible to exactly the viewers its
# image is visible to. The pipeline is exempt; admins are not; a viewer with
# no verified Matrix identity sees no Matrix post; a site asset is seen by
# every verified viewer. Behind gate3_matrix_posts_enforced?, which ships off.
class Gate3MatrixPostsTest < ActionDispatch::IntegrationTest
  MXID = "@member:41chan.net"

  def md5 = SecureRandom.hex(16)

  def answer(rooms, mxid: MXID)
    body = { mxid: mxid, rooms: rooms.sort, count: rooms.size, digest: "d", as_of: Time.zone.now.iso8601 }.to_json
    HTTP::Response.new(status: 200, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" })
  end

  # The viewer is joined to `rooms` (as fourier-auth answers for MXID).
  def joined(*rooms)
    Danbooru::Http.any_instance.stubs(:get).returns(answer(rooms))
  end

  def placed!(post, rooms, site_asset: false)
    ids = MatrixRoom.intern!(rooms)
    MatrixMedia.create!(mxc: post.source, room_ids: rooms.map { ids.fetch(it) }.sort, site_asset: site_asset, snapshot_head: 1, snapshot_at: Time.zone.now)
    PostMxc.recompute_room_ids!([post.id])
    post.reload
  end

  # The fixtures hidden from `user`, asked one post at a time and as the
  # relation; the two must agree.
  def hidden(user)
    CurrentUser.set(user: user, request: @request) do
      CreatorVisibility.forget!
      one = [@plain, @art, @avatar, @unknown].select { it.reload.hidden_from?(user) }.map(&:id)
      relation = Post.hidden_from(user) # nil: nothing is hidden from this viewer
      set = relation.nil? ? [] : relation.where(id: [@plain, @art, @avatar, @unknown].map(&:id)).order(:id).pluck(:id)
      assert_equal one.sort, set, "the per-post rule and the relation must agree"
      one.sort
    end
  end

  def verified = { "X-Fourier-Identity" => MXID }

  def search_ids(user, tags: "gate3_tag", headers: verified)
    if user
      get_auth posts_path(format: :json), user, params: { tags: tags, limit: 100 }, headers: headers
    else
      get posts_path(format: :json), params: { tags: tags, limit: 100 }, headers: headers
    end
    assert_response :success
    response.parsed_body.pluck("id")
  end

  setup do
    cookies["fourier_session"] = "session-of-member"
    Danbooru::Http.any_instance.stubs(:get).returns(answer([]))
    @member = create(:user)
    @uploader = create(:approver_user, name: "tunnel")
    as(@uploader) do
      @plain = create(:post, md5: md5, uploader: @uploader, tag_string: "gate3_tag", source: "https://boards.4chan.org/a/thread/1")
      @art = create(:post, md5: md5, uploader: @uploader, tag_string: "gate3_tag", source: "mxc://41chan.net/art")
      @avatar = create(:post, md5: md5, uploader: @uploader, tag_string: "gate3_tag", source: "mxc://41chan.net/avatar")
      @unknown = create(:post, md5: md5, uploader: @uploader, tag_string: "gate3_tag", source: "mxc://41chan.net/unknown")
      @newest = create(:post, md5: md5, uploader: @uploader, tag_string: "gate3_tag", source: "https://boards.4chan.org/a/thread/2")
    end
    placed!(@art, ["!art:41chan.net"])
    placed!(@avatar, ["!private:41chan.net"], site_asset: true)
    CreatorVisibility.forget!
  end

  context "with the switch off" do
    should "show every post, as before" do
      assert_equal [@newest, @unknown, @avatar, @art, @plain].map(&:id), search_ids(@member, headers: {})
    end
  end

  context "with the switch on" do
    setup do
      Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
    end

    should "show a member of the room its post, and hide the rest" do
      joined("!art:41chan.net")
      assert_equal [@newest, @avatar, @art, @plain].map(&:id), search_ids(@member)
    end

    should "hide a Matrix post from a verified viewer outside its rooms, showing site assets" do
      joined("!elsewhere:41chan.net")
      assert_equal [@newest, @avatar, @plain].map(&:id), search_ids(@member)
    end

    should "show no Matrix post to a viewer with no verified identity, site assets included" do
      assert_equal [@newest, @plain].map(&:id), search_ids(@member, headers: {})
      assert_equal [@newest, @plain].map(&:id), search_ids(nil, headers: {})
    end

    should "show no Matrix post when fourier-auth cannot answer" do
      Danbooru::Http.any_instance.stubs(:get).returns(HTTP::Response.new(status: 503, body: "", version: "1.1", request: nil))
      assert_equal [@newest, @plain].map(&:id), search_ids(@member)
    end

    should "hold admins to it" do
      joined("!elsewhere:41chan.net")
      assert_equal [@newest, @avatar, @plain].map(&:id), search_ids(create(:admin_user))
      assert_equal [@newest, @avatar, @plain].map(&:id), search_ids(create(:owner_user))
    end

    should "spare the pipeline" do
      Danbooru::Http.any_instance.expects(:get).never
      all = [@newest, @unknown, @avatar, @art, @plain].map(&:id)
      assert_equal all, search_ids(@uploader, headers: {})
      assert_equal all, search_ids(create(:approver_user, name: "sample"), headers: {})
    end

    should "answer the post page 404 outside its rooms, and open it inside" do
      joined("!elsewhere:41chan.net")
      get_auth post_path(@art), @member, headers: verified
      assert_response 404
      get_auth post_path(@art, format: :json), @member, headers: verified
      assert_response 404

      Rails.cache.clear
      CreatorVisibility.forget!
      joined("!art:41chan.net")
      get_auth post_path(@art), @member, headers: verified
      assert_response :success
    end

    should "skip a hidden post in the neighbours" do
      joined("!elsewhere:41chan.net")
      get_auth show_seq_post_path(@avatar), @member, params: { seq: "next", q: "gate3_tag" }, headers: verified
      assert_redirected_to post_path(@plain, q: "gate3_tag")
    end

    should "hide it from an md5 search" do
      joined("!elsewhere:41chan.net")
      assert_equal [], search_ids(@member, tags: "md5:#{@art.md5}")
    end

    should "leave counts as they are" do
      joined("!elsewhere:41chan.net")
      get_auth posts_counts_path(format: :json), @member, params: { tags: "gate3_tag" }, headers: verified
      assert_equal 5, response.parsed_body.dig("counts", "posts")
    end

    should "write the overlap inline, beside the tag condition, in one query" do
      joined("!art:41chan.net")
      art = MatrixRoom.find_by!(room_id: "!art:41chan.net").id
      sql = CurrentUser.set(user: @member, request: ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => MXID, "HTTP_COOKIE" => "fourier_session=s")) do
        PostQuery.normalize("gate3_tag", current_user: @member).with_implicit_metatags.posts.to_sql
      end
      assert_includes sql, "posts.room_ids && '{-1,0,#{art}}'::integer[]"
      assert_includes sql, "gate3_tag"
    end
  end

  context "Post#hidden_from? and Post.hidden_from, with the switch on" do
    setup do
      Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
      @request = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => MXID, "HTTP_COOKIE" => "fourier_session=s")
    end

    should "agree row for row, for a member in and out of the room, an admin and the pipeline" do
      joined("!art:41chan.net")
      assert_equal [@unknown.id], hidden(@member)

      Rails.cache.clear
      joined("!elsewhere:41chan.net")
      assert_equal [@art.id, @unknown.id], hidden(create(:admin_user))
      assert_equal [], hidden(@uploader)
    end

    should "keep a hidden post out of the listings of records that name it" do
      joined("!elsewhere:41chan.net")
      fav = as(@member) { create(:favorite, post: @art, user: @member) }
      listed = CurrentUser.set(user: @member, request: @request) { Favorite.without_hidden_posts(@member).where(id: fav.id).to_a }
      assert_equal [], listed
    end
  end
end
