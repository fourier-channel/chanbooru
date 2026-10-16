# frozen_string_literal: true

require "test_helper"

# holds:<identity> -- the posts holding an image by ANY of its identities
# (operator, 2026-10-16: "No copies of objects, is a given"). One picture can
# be known by several names, and a caller holding one of them needs the post:
#
#   holds:mxc://...   post_mxcs.mxc (the post's own Matrix source, and every
#                     ALIAS the tunnel's duplicate path mapped to it) and
#                     posts.source
#   holds:<32 hex>    posts.md5, and the generation record's other md5 for
#                     the same upload (FourierGenerationMetadata: the md5 the
#                     tunnel was handed, raw_md5, and the md5 of the stripped
#                     bytes it posted) mapped to the post carrying it
#
# A metatag on the EXISTING posts search (no new route), so every rule a
# search obeys holds: a viewer gets only the posts they may see, and a
# signed-out visitor's narrowed search does not admit it.
class HoldsMetatagTest < ActionDispatch::IntegrationTest
  GATED = "child" # in Danbooru.config.restricted_tags
  MXID = "@member:41chan.net"

  def md5 = SecureRandom.hex(16)

  def ids_for(user, tags, headers: {})
    if user
      get_auth posts_path(format: :json), user, params: { tags: tags, limit: 100 }, headers: headers
    else
      get posts_path(format: :json), params: { tags: tags, limit: 100 }, headers: headers
    end
    assert_response :success
    response.parsed_body.pluck("id").sort
  end

  setup do
    @tunnel = create(:approver_user, name: "tunnel")
    @member = create(:user)
    @gold = create(:gold_user)
    @admin = create(:admin_user)
    as(@tunnel) do
      @chan = create(:post, uploader: @tunnel, md5: md5, tag_string: "holds_test", source: "https://boards.4chan.org/b/thread/1")
      @gated = create(:post, uploader: @tunnel, md5: md5, tag_string: "holds_test #{GATED}", source: "https://boards.4chan.org/b/thread/2")
      @matrix = create(:post, uploader: @tunnel, md5: md5, tag_string: "holds_test", source: "mxc://41chan.net/own")
      @other = create(:post, uploader: @tunnel, md5: md5, tag_string: "holds_test", source: "https://boards.4chan.org/b/thread/3")
    end
    # The tunnel's duplicate path: the same bytes re-uploaded in Matrix are
    # another address of the 4chan post's image.
    assert_equal :accepted, PostMxc.record_alias!(@chan, "mxc://41chan.net/aliased")
    # The upload whose stripped bytes are @chan's file.
    @raw = md5
    FourierGenerationMetadata.create!(md5: @chan.md5, raw_md5: @raw, source: "matrix", poster: MXID, fields: { "png:parameters" => "x" })
  end

  should "find a post by its own mxc source and by an alias mapped to it" do
    assert_equal [@matrix.id], ids_for(@member, "holds:mxc://41chan.net/own")
    assert_equal [@chan.id], ids_for(@member, "holds:mxc://41chan.net/aliased")
    assert_equal [], ids_for(@member, "holds:mxc://41chan.net/nothing")
  end

  should "find a post by its md5, and by the raw md5 of the upload it was stripped from" do
    assert_equal [@chan.id], ids_for(@member, "holds:#{@chan.md5}")
    assert_equal [@chan.id], ids_for(@member, "holds:#{@raw}")
    assert_equal [@chan.id], ids_for(@member, "holds:#{@raw.upcase}")
    assert_equal [], ids_for(@member, "holds:#{md5}")
  end

  should "find the post still holding the raw upload by the stripped md5 too" do
    raw_post = as(@tunnel) { create(:post, uploader: @tunnel, md5: @raw, tag_string: "holds_test", source: "https://example.com/raw") }
    assert_equal [@chan.id, raw_post.id].sort, ids_for(@member, "holds:#{@chan.md5}")
    assert_equal [@chan.id, raw_post.id].sort, ids_for(@member, "holds:#{@raw}")
  end

  should "compose with the rest of the search, negated too" do
    assert_equal [@chan.id], ids_for(@member, "holds_test holds:#{@raw}")
    assert_equal [@other.id, @matrix.id].sort, ids_for(@member, "holds_test -holds:#{@raw}")
  end

  should "find nothing for a value that is neither an mxc nor an md5" do
    assert_equal [], ids_for(@member, "holds:banana")
    assert_equal [], ids_for(@member, "holds:#{md5}0")
  end

  should "show a viewer only the posts they may see" do
    assert_equal [], ids_for(@member, "holds:#{@gated.md5}")
    assert_equal [@gated.id], ids_for(@gold, "holds:#{@gated.md5}")

    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN) # production's
    as(@admin) { @chan.delete!("test", user: @admin) }
    assert_equal [], ids_for(@member, "holds:mxc://41chan.net/aliased")
    assert_equal [@chan.id], ids_for(@admin, "holds:mxc://41chan.net/aliased")
  end

  context "with gate 3 on" do
    setup do
      Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
      cookies["fourier_session"] = "session-of-member"
      body = { mxid: MXID, rooms: [], count: 0, digest: "d", as_of: Time.zone.now.iso8601 }.to_json
      Danbooru::Http.any_instance.stubs(:get).returns(HTTP::Response.new(status: 200, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" }))
    end

    should "hide a Matrix post outside the viewer's rooms, and keep a booru post found by its alias" do
      verified = { "X-Fourier-Identity" => MXID }
      assert_equal [], ids_for(@member, "holds:mxc://41chan.net/own", headers: verified)
      assert_equal [], ids_for(@admin, "holds:mxc://41chan.net/own", headers: verified)
      assert_equal [@chan.id], ids_for(@member, "holds:mxc://41chan.net/aliased", headers: verified)
    end
  end

  should "not be admitted to a signed-out search, in json or html" do
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    get posts_path(format: :json), params: { tags: "holds:#{@chan.md5}" }
    assert_response 404
    get posts_path(format: :json), params: { tags: "holds:#{@chan.md5}", only: "md5,is_deleted,source" }
    assert_response 404
    get posts_path, params: { tags: "holds:mxc://41chan.net/aliased" }
    assert_response 404
  end

  should "not count against the tag limit" do
    tags = (["holds:#{@raw}"] * 3).join(" ")
    assert_equal [@chan.id], ids_for(@member, tags)
  end
end
