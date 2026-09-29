require "test_helper"

# POST /fourier/posts/:post_id/creator.json -- who made a post, recorded once
# (operator ruling 2026-09-29), driven the way the tunnel drives it: a JSON
# body, as the posting bot. The record is what FourierCreatorPrivacy trusts,
# so the property that matters is that it is written once and never replaced.
class FourierPostCreatorsControllerTest < ActionDispatch::IntegrationTest
  CREATOR = "@alice:41chan.net"

  def record(post_id, mxid, as_user: @bot)
    post_auth "/fourier/posts/#{post_id}/creator.json", as_user, as: :json, params: { mxid: mxid }
  end

  context "POST /fourier/posts/:post_id/creator" do
    setup do
      @bot = create(:builder_user)
      @post = create(:post, uploader: @bot)
    end

    should "record the creator for a builder" do
      record(@post.id, CREATOR)

      assert_response :success
      assert_equal({ "post_id" => @post.id, "mxid" => CREATOR }, response.parsed_body)
      row = FourierPostCreator.find_by!(post_id: @post.id)
      assert_equal CREATOR, row.mxid
      assert_equal @bot.id, row.recorded_by
    end

    should "answer a repeat of the same creator with 200, case-insensitively, and keep one row" do
      record(@post.id, CREATOR)
      record(@post.id, "@ALICE:41chan.net")

      assert_response :success
      assert_equal CREATOR, response.parsed_body["mxid"], "the stored spelling is the answer"
      assert_equal 1, FourierPostCreator.where(post_id: @post.id).count
    end

    should "refuse a different creator with 409, error and fix, and never overwrite" do
      record(@post.id, CREATOR)
      record(@post.id, "@mallory:41chan.net")

      assert_response 409
      assert response.parsed_body["error"].present?
      assert response.parsed_body["fix"].present?
      assert_equal "creator_mismatch", response.parsed_body["reason"]
      assert_equal CREATOR, FourierPostCreator.find_by!(post_id: @post.id).mxid

      # Not by any other builder either, nor by an admin.
      record(@post.id, "@mallory:41chan.net", as_user: create(:admin_user))
      assert_response 409
      assert_equal CREATOR, FourierPostCreator.find_by!(post_id: @post.id).mxid
    end

    should "answer a malformed mxid with 422, error and fix, and record nothing" do
      ["alice", "@alice", "alice:41chan.net", "@al ice:41chan.net", "@alice:41chan.net\u0000", "@alice:41chan\n.net",
       "@#{"a" * 250}:41chan.net", "", nil, 7, ["@alice:41chan.net"]].each do |mxid|
        record(@post.id, mxid)

        assert_response 422, mxid.inspect
        assert response.parsed_body["error"].present?, mxid.inspect
        assert response.parsed_body["fix"].present?, mxid.inspect
      end
      refute FourierPostCreator.exists?(post_id: @post.id)
    end

    should "answer a missing post with 404, error and fix" do
      record(0, CREATOR)

      assert_response 404
      assert response.parsed_body["fix"].present?
      assert_equal 0, FourierPostCreator.count
    end

    should "refuse a member and an anonymous caller with 403 and record nothing" do
      record(@post.id, CREATOR, as_user: create(:user))
      assert_response 403

      reset!
      post "/fourier/posts/#{@post.id}/creator.json", as: :json, params: { mxid: CREATOR }
      assert_response 403

      refute FourierPostCreator.exists?(post_id: @post.id)
    end

    # The foreign key cascades: a post that is gone has no creator, and the
    # row never blocks the delete. Deleted at the database, as expunge! ends,
    # because the factory's media asset has no files for expunge! to trash.
    should "go with the post when the post is deleted" do
      record(@post.id, CREATOR)
      assert FourierPostCreator.exists?(post_id: @post.id)
      Post.where(id: @post.id).delete_all

      refute FourierPostCreator.exists?(post_id: @post.id)
    end
  end
end
