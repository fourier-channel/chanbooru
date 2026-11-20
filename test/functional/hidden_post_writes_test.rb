# frozen_string_literal: true

require "test_helper"

# R1 (operator 2026-11-20): a post hidden from a writer is not writable by
# that writer; the write is refused as not found, like the read. Until then
# Post#writable_by? let every approver, moderator and admin write a post
# hidden from them only as DELETED or JAILED -- edit it, favorite it, vote
# on it, comment on it, undelete it, adopt it as a parent and move a child's
# favorites onto it -- and each of those writes answered with the post.
#
# Only the pipeline (TagBanishment.pipeline?: the jail panel's account and
# the posting bots) writes past hidden_from?, and of those only an approver:
# sample deletes and jails posts it cannot see. An admin who sees deleted
# posts was never hidden from them and writes them as before.
#
# Deleted-post visibility and the banished-post rule are relaxed under test,
# so both are stubbed to the production shape, and every refusal below first
# asserts the post really is hidden from the writer: a green here is about
# the guard, not the setup.
class HiddenPostWritesTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  JAIL = "troll_jail"

  context "With deleted and jailed posts hidden as in production" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!
      # The fixtures delete posts within the hour, and an early deletion
      # costs a builder five upload slots (UploadLimit): tunnel could upload
      # no more. The limit is not what these tests are about.
      UploadLimit.any_instance.stubs(:limited?).returns(false)

      @moderator = create(:moderator_user)
      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @tunnel = create(:builder_user, name: "tunnel")
      @fan = create(:gold_user)

      @deleted = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
      @deleted.delete!("ordinary deletion", user: @admin)
      @live = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
      @deleted.reload

      assert @deleted.hidden_from?(@moderator), "fixture: a deleted post is hidden from a moderator"
      assert @deleted.hidden_from?(@sample), "fixture: a deleted post is hidden from sample"
      assert_not @deleted.hidden_from?(@admin), "fixture: an admin sees a deleted post"
      assert_not @live.hidden_from?(@moderator), "fixture: the live post is not hidden"
    end

    should "refuse a moderator's edit of a deleted post as not found" do
      put_auth post_path(@deleted, format: :json), @moderator, params: { post: { tag_string: "landscape r1_edit" }}

      assert_response 404
      assert_not_includes @deleted.reload.tag_array, "r1_edit"
    end

    should "refuse a moderator's favorite, vote and comment on a deleted post as not found" do
      post_auth favorites_path(format: :json), @moderator, params: { post_id: @deleted.id }
      assert_response 404
      post_auth post_post_votes_path(@deleted, format: :json), @moderator, params: { score: 1 }
      assert_response 404
      post_auth comments_path(format: :json), @moderator, params: { comment: { post_id: @deleted.id, body: "r1 comment" }}
      assert_response 404

      assert_equal 0, Favorite.where(post: @deleted, user: @moderator).count
      assert_equal 0, PostVote.where(post: @deleted, user: @moderator).count
      assert_equal 0, Comment.where(post: @deleted).count
    end

    should "refuse a moderator's approval of a deleted post as not found, leaving it deleted" do
      post_auth post_approvals_path(format: :json), @moderator, params: { post_id: @deleted.id }

      assert_response 404
      assert @deleted.reload.is_deleted?
    end

    should "refuse a moderator's delete-off from the pill as not found" do
      login_as(@moderator)
      patch modulation_moderation_path(@deleted), params: { deleted: false }, as: :json

      assert_response 404
      assert @deleted.reload.is_deleted?
    end

    should "not let a moderator adopt a deleted post as a parent" do
      put_auth post_path(@live, format: :json), @moderator, params: { post: { parent_id: @deleted.id }}

      assert_nil @live.reload.parent_id
      assert_not @deleted.reload.has_children?
    end

    should "refuse a moderator's delete that moves favorites onto a deleted parent, saying why" do
      child = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
      child.update_columns(parent_id: @deleted.id)
      create(:favorite, post: child, user: @fan)

      delete_auth post_path(child), @moderator, params: { commit: "Delete", post: { reason: "duplicate", move_favorites: "1" }}

      assert_response 403
      assert_includes response.body, ERB::Util.html_escape(Post::NO_PARENT_FOR_FAVORITES)
      assert_not child.reload.is_deleted?, "a delete that moved nothing must not report success"
      assert_equal 0, Favorite.where(post: @deleted).count
      assert_equal 1, Favorite.where(post: child).count
    end

    should "refuse moving favorites from a post with no parent in the same words as from a hidden one" do
      orphan = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }

      delete_auth post_path(orphan), @moderator, params: { commit: "Delete", post: { reason: "duplicate", move_favorites: "1" }}

      assert_response 403
      assert_includes response.body, ERB::Util.html_escape(Post::NO_PARENT_FOR_FAVORITES)
      assert_not orphan.reload.is_deleted?
    end

    should "refuse an admin's edit of a jailed post as not found" do
      banish_tags!("gore")
      jailed = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape gore") }.reload
      assert jailed.is_deleted? && jailed.has_tag?(JAIL), "fixture: the booru jailed it"
      assert jailed.hidden_from?(@admin), "fixture: a jailed post is hidden from an admin"

      put_auth post_path(jailed, format: :json), @admin, params: { post: { tag_string: "#{jailed.tag_string} r1_edit" }}

      assert_response 404
      assert_not_includes jailed.reload.tag_array, "r1_edit"
    end

    # Controls: the writers R1 leaves alone.
    should "let sample, an approver in the pipeline, edit a deleted post it cannot see" do
      put_auth post_path(@deleted, format: :json), @sample, params: { post: { tag_string: "landscape r1_edit" }}

      assert_response :success
      assert_includes @deleted.reload.tag_array, "r1_edit"
    end

    should "not let tunnel, in the pipeline but no approver, write a deleted post it did not upload" do
      other = create(:post, tag_string: "landscape")
      other.delete!("ordinary deletion", user: @admin)
      assert other.reload.hidden_from?(@tunnel), "fixture: hidden from tunnel"

      put_auth post_path(other, format: :json), @tunnel, params: { post: { tag_string: "landscape r1_edit" }}

      assert_response 404
    end

    should "let an admin, who sees deleted posts, edit one" do
      put_auth post_path(@deleted, format: :json), @admin, params: { post: { tag_string: "landscape r1_edit" }}

      assert_response :success
      assert_includes @deleted.reload.tag_array, "r1_edit"
    end

    should "let the uploader edit its own deleted post" do
      assert_not @deleted.hidden_from?(@tunnel), "fixture: the uploader sees its own deletion"
      put_auth post_path(@deleted, format: :json), @tunnel, params: { post: { tag_string: "landscape r1_edit" }}

      assert_response :success
      assert_includes @deleted.reload.tag_array, "r1_edit"
    end

    should "let a moderator delete a live post" do
      delete_auth post_path(@live), @moderator, params: { commit: "Delete", post: { reason: "duplicate" }}

      assert @live.reload.is_deleted?
    end

    # A form for a new record naming a post drew itself for a missing post
    # and refused a hidden one, which told them apart (review 2026-11-20).
    should "answer a form door for a hidden post exactly as for a missing one" do
      missing = Post.maximum(:id) + 1000
      doors = {
        "flag" => ->(id) { new_post_flag_path(format: :json, post_flag: { post_id: id }) },
        "appeal" => ->(id) { new_post_appeal_path(format: :json, post_appeal: { post_id: id }) },
        "comment" => ->(id) { new_comment_path(format: :json, comment: { post_id: id }) },
        "note preview" => ->(id) { preview_notes_path(format: :json, note: { post_id: id, body: "r1", x: 1, y: 1, width: 10, height: 10 }) },
      }
      doors.each do |door, path|
        answers = [@deleted.id, missing].map do |id|
          get_auth path.call(id), @moderator
          [response.status, response.parsed_body.except("backtrace")]
        end
        assert_equal 404, answers.first.first, "#{door} for a hidden post"
        assert_equal answers.first, answers.last, door
      end

      get_auth new_post_flag_path(post_flag: { post_id: @live.id }), @moderator
      assert_response :success, "control: the flag form for a post that exists"
    end

    # A reaction and a report name their target polymorphically, so the
    # write rule refused a hidden target as not found while a missing one
    # reached validation and answered 422 "must exist" (boo.122).
    should "refuse a reaction or a report on a hidden target exactly as on a missing one" do
      commented = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
      comment = as(@fan) { create(:comment, post: commented, creator: @fan) }
      commented.delete!("ordinary deletion", user: @admin)
      assert comment.reload.post.hidden_from?(@moderator), "fixture: the comment's post is hidden"
      missing_post = Post.maximum(:id) + 1000
      missing_comment = Comment.maximum(:id) + 1000

      # Without the backtrace: the test env shows it to everyone, and it names
      # the test line that made the call, so two calls never match on it.
      answer = lambda do |path, params|
        post_auth path, @moderator, params: params
        [response.status, response.parsed_body.except("backtrace")]
      end
      [["Post", @deleted.id, missing_post], ["Comment", comment.id, missing_comment]].each do |type, hidden, missing|
        refused = answer.call(reactions_path(format: :json), { reaction: { model_type: type, model_id: hidden, reaction_id: 1 }})
        assert_equal 404, refused.first, "reaction to a hidden #{type}"
        assert_equal answer.call(reactions_path(format: :json), { reaction: { model_type: type, model_id: missing, reaction_id: 1 }}), refused, "reaction to a #{type}"
      end
      refused = answer.call(moderation_reports_path(format: :json), { moderation_report: { model_type: "Comment", model_id: comment.id, reason: "r1" }})
      assert_equal 404, refused.first, "report on a hidden comment"
      assert_equal answer.call(moderation_reports_path(format: :json), { moderation_report: { model_type: "Comment", model_id: missing_comment, reason: "r1" }}), refused, "report"
      assert_equal 0, Reaction.where(creator: @moderator).count
      assert_equal 0, ModerationReport.where(creator: @moderator).count
    end
  end
end
