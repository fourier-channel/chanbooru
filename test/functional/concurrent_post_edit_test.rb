# frozen_string_literal: true

require "test_helper"

# boo.122 D3 (2026-11-20): PostsController#update read the post, merged the
# edit into the copy it read (old_tag_string, the three-way merge in
# Post#merge_old_changes) and saved the whole tag_string. Two writers on one
# post at once each merged into their own stale copy, and the later save
# erased the earlier one's tags. sampling's tag push and its jail run 250 ms
# apart as the same account, and 429 production posts lost troll_jail so --
# deleted as jailed, no longer carrying the tag.
#
# The race is replayed here by handing the update a copy read BEFORE another
# writer's save: exactly what the slower of two concurrent requests holds.
class ConcurrentPostEditTest < ActionDispatch::IntegrationTest
  context "An edit that read the post before another writer saved it" do
    setup do
      @user = create(:user)
      @post = as(@user) { create(:post, tag_string: "landscape") }
      @stale = Post.find(@post.id)
      as(@user) { @post.update!(tag_string: "landscape other_writer_tag") }
      Post.stubs(:find_writable!).returns(@stale)
    end

    should "keep the tag the other writer added" do
      put_auth post_path(@post, format: :json), @user, params: { post: { tag_string: "landscape this_writer_tag", old_tag_string: "landscape" }}

      assert_response :success
      assert_equal %w[landscape other_writer_tag this_writer_tag], @post.reload.tag_array.sort
    end
  end
end
