require "test_helper"
require Rails.root.join("db/migrate/20261015000001_add_room_ids_to_posts.rb").to_s

# GATE 3 FOR POSTS, the record (fourier-basis docs/design/GATE3_MATRIX_POSTS.md,
# piece D): post_mxcs maps every address of a post's image to it, and
# posts.room_ids is derived from those rows and matrix_media -- {0} for a
# post that is not a Matrix post, the union of its mxcs' rooms (and -1 for a
# site asset) for one that is, {} while none of its mxcs has an answer.
class Gate3MatrixRecordsTest < ActiveSupport::TestCase
  def md5 = SecureRandom.hex(16)

  def mxc_post(mxc = "mxc://41chan.net/#{SecureRandom.hex(8)}", **attrs)
    create(:post, md5: md5, source: mxc, **attrs)
  end

  def answer!(mxc, rooms:, site_asset: false, head: 100)
    ids = MatrixRoom.intern!(rooms)
    MatrixMedia.create!(mxc: mxc, uploader: "@up:41chan.net", site_asset: site_asset, room_ids: rooms.map { |r| ids.fetch(r) }.sort,
                        snapshot_head: head, snapshot_at: Time.zone.now)
  end

  def room_id(room) = MatrixRoom.find_by!(room_id: room).id

  context "the migration" do
    setup do
      @migration = AddRoomIdsToPosts.new
      @migration.verbose = false
    end

    should "map every mxc:// post to its source and close it, and leave every other post open" do
      matrix = mxc_post("mxc://41chan.net/seeded1")
      plain = create(:post, md5: md5, source: "https://boards.4chan.org/a/thread/1")
      # As the posts stood before the migration: no mapping, the column's default.
      PostMxc.delete_all
      Post.where(id: [matrix.id, plain.id]).update_all(room_ids: [0])

      stub_const(AddRoomIdsToPosts, :BATCH, 1) { @migration.seed! }

      assert_equal [[matrix.id, "mxc://41chan.net/seeded1", "post_source"]], PostMxc.pluck(:post_id, :mxc, :source)
      assert_equal [], matrix.reload.room_ids
      assert_equal [0], plain.reload.room_ids
    end

    should "be safe to run again" do
      matrix = mxc_post("mxc://41chan.net/seeded2")
      2.times { @migration.seed! }
      assert_equal 1, PostMxc.where(post_id: matrix.id).count
    end
  end

  context "a new post" do
    should "carry {0} when it is not a Matrix post" do
      assert_equal [0], create(:post, md5: md5, source: "https://example.com/a.png").room_ids
    end

    should "be mapped to its own mxc, and closed while that mxc has no answer" do
      post = mxc_post("mxc://41chan.net/fresh")
      assert_equal "post_source", PostMxc.find_by!(mxc: "mxc://41chan.net/fresh").source
      assert_equal post.id, PostMxc.find_by!(mxc: "mxc://41chan.net/fresh").post_id
      assert_equal [], post.reload.room_ids
    end

    should "open to its rooms at once when its mxc was answered for before it was posted" do
      answer!("mxc://41chan.net/early", rooms: ["!a:41chan.net"])
      post = mxc_post("mxc://41chan.net/early")
      assert_equal [room_id("!a:41chan.net")], post.reload.room_ids
    end

    should "stay closed when its mxc already belongs to another post" do
      first = mxc_post("mxc://41chan.net/taken")
      answer!("mxc://41chan.net/taken", rooms: ["!a:41chan.net"])
      PostMxc.recompute_room_ids!([first.id])
      second = create(:post, md5: md5, source: "mxc://41chan.net/taken")
      assert_equal first.id, PostMxc.find_by!(mxc: "mxc://41chan.net/taken").post_id
      assert_equal [], second.reload.room_ids
    end
  end

  context "recomputing posts.room_ids" do
    should "take the sorted union of every mxc's rooms" do
      post = mxc_post("mxc://41chan.net/one")
      PostMxc.create!(post: post, mxc: "mxc://41chan.net/two", source: PostMxc::ALIAS)
      answer!("mxc://41chan.net/one", rooms: ["!b:41chan.net", "!a:41chan.net"])
      answer!("mxc://41chan.net/two", rooms: ["!c:41chan.net", "!a:41chan.net"])

      PostMxc.recompute_room_ids!([post.id])

      assert_equal %w[!a:41chan.net !b:41chan.net !c:41chan.net].map { room_id(it) }.sort, post.reload.room_ids
    end

    should "add -1 when any of its mxcs is a site asset" do
      post = mxc_post("mxc://41chan.net/avatar")
      answer!("mxc://41chan.net/avatar", rooms: ["!a:41chan.net"], site_asset: true)
      PostMxc.recompute_room_ids!([post.id])
      assert_equal [-1, room_id("!a:41chan.net")], post.reload.room_ids
    end

    should "leave {} when none of its mxcs has an answer, and use the answered ones otherwise" do
      post = mxc_post("mxc://41chan.net/unknown")
      PostMxc.create!(post: post, mxc: "mxc://41chan.net/also-unknown", source: PostMxc::ALIAS)
      PostMxc.recompute_room_ids!([post.id])
      assert_equal [], post.reload.room_ids

      answer!("mxc://41chan.net/also-unknown", rooms: ["!z:41chan.net"])
      PostMxc.recompute_room_ids!([post.id])
      assert_equal [room_id("!z:41chan.net")], post.reload.room_ids
    end

    should "keep {0} for a booru post whose bytes were re-uploaded in Matrix" do
      post = create(:post, md5: md5, source: "https://boards.4chan.org/a/thread/2")
      assert_equal :accepted, PostMxc.record_alias!(post, "mxc://41chan.net/reupload")
      answer!("mxc://41chan.net/reupload", rooms: ["!a:41chan.net"])
      PostMxc.recompute_room_ids!([post.id])
      assert_equal [0], post.reload.room_ids
    end

    should "not touch a post whose set is unchanged" do
      post = mxc_post("mxc://41chan.net/same")
      answer!("mxc://41chan.net/same", rooms: ["!a:41chan.net"])
      PostMxc.recompute_room_ids!([post.id])
      before = post.reload.updated_at
      assert_no_difference(-> { Post.where(id: post.id, room_ids: [room_id("!a:41chan.net")]).count }) { PostMxc.recompute_room_ids!([post.id]) }
      assert_equal before, post.reload.updated_at
    end

    should "leave Tag.post_count alone" do
      post = mxc_post("mxc://41chan.net/counted", tag_string: "gate3_counted_tag")
      count = Tag.find_by_name("gate3_counted_tag").post_count
      answer!("mxc://41chan.net/counted", rooms: ["!a:41chan.net"])
      PostMxc.recompute_room_ids!([post.id])
      assert_equal count, Tag.find_by_name("gate3_counted_tag").post_count
    end
  end

  context "an alias" do
    setup do
      @post = mxc_post("mxc://41chan.net/orig")
    end

    should "be recorded once, whoever reports it how often" do
      2.times { assert_equal :accepted, PostMxc.record_alias!(@post, "mxc://41chan.net/dup") }
      assert_equal 1, PostMxc.where(mxc: "mxc://41chan.net/dup").count
    end

    should "be refused when the mxc already belongs to another post" do
      other = mxc_post("mxc://41chan.net/other")
      assert_equal :mxc_mapped_elsewhere, PostMxc.record_alias!(@post, "mxc://41chan.net/other")
      assert_equal other.id, PostMxc.find_by!(mxc: "mxc://41chan.net/other").post_id
    end

    should "be removed with the post when the post is expunged" do
      PostMxc.record_alias!(@post, "mxc://41chan.net/gone")
      @post.destroy!
      assert_not PostMxc.exists?(post_id: @post.id)
    end
  end
end
