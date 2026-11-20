# frozen_string_literal: true

require "test_helper"

# boo.122 D5 (2026-11-20): a pool took any post id at all -- a pool edit, a
# revert, a pool:N metatag -- so a member could seat a jailed or deleted post
# they are told does not exist, or a post id nobody has yet, and the pool's
# versions and post_ids_include searches then answered for it.
# Pool#added_posts_exist_for_writer now refuses an added id that is not a
# post existing for the writer, with one message for missing and hidden, as
# FavoriteGroup#validate_posts already did for its creator.
class PoolHiddenPostsTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  REFUSED = /Cannot add invalid post\(s\) to pool/

  context "A pool and a post hidden from its editor" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!

      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @member = create(:user, created_at: 2.weeks.ago)
      @uploader = create(:contributor_user) # posts several fixtures: no upload limit

      @live = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @jailed = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@sample) { @jailed.update!(tag_string: "landscape #{JAIL}") }
      @jailed.reload.delete!("troll jail: shock", user: @sample)
      @deleted = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @deleted.delete!("duplicate", user: @admin)

      @pool = as(@member) { create(:pool, post_ids: [@live.id]) }

      assert @jailed.reload.hidden_from?(@member), "fixture: the jailed post is hidden from the member"
      assert @deleted.reload.hidden_from?(@member), "fixture: the deleted post is hidden from the member"
      assert_not @deleted.hidden_from?(@admin), "fixture: an admin sees the ordinary deletion"
      RateLimit.delete_all
    end

    should "refuse a hidden post and a missing one alike in an edit" do
      missing = Post.maximum(:id) + 1000
      bodies = [@jailed.id, @deleted.id, missing].map do |id|
        RateLimit.delete_all
        put_auth pool_path(@pool, format: :json), @member, params: { pool: { post_ids: [@live.id, id] }}
        assert_response 422, "post ##{id}: #{response.body}"
        assert_match REFUSED, response.body
        assert_equal [@live.id], @pool.reload.post_ids, "post ##{id} was seated"
        response.body.gsub(id.to_s, "N")
      end
      assert_equal 1, bodies.uniq.size, "the refusals tell missing and hidden apart: #{bodies.uniq}"
    end

    should "take a post that exists for the editor" do
      other = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      put_auth pool_path(@pool, format: :json), @member, params: { pool: { post_ids: [@live.id, other.id] }}
      assert_response :success, response.body
      assert_equal [@live.id, other.id], @pool.reload.post_ids
    end

    should "let an admin add an ordinary deletion, which an admin sees, but not a jailed post" do
      put_auth pool_path(@pool, format: :json), @admin, params: { pool: { post_ids: [@live.id, @deleted.id] }}
      assert_response :success, response.body
      assert_includes @pool.reload.post_ids, @deleted.id

      RateLimit.delete_all
      put_auth pool_path(@pool, format: :json), @admin, params: { pool: { post_ids: [@live.id, @deleted.id, @jailed.id] }}
      assert_response 422
      assert_not_includes @pool.reload.post_ids, @jailed.id
    end

    should "keep a post already in the pool that has since been hidden" do
      kept = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@member) { @pool.update!(post_ids: [@live.id, kept.id]) }
      kept.delete!("duplicate", user: @admin)

      other = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      put_auth pool_path(@pool, format: :json), @member, params: { pool: { post_ids: [@live.id, other.id] }}
      assert_response :success, response.body
      assert_includes @pool.reload.post_ids, kept.id, "an edit by a member who cannot see it keeps it"
      assert_includes @pool.post_ids, other.id
    end

    should "revert without a post now hidden, counting it and never naming it" do
      # Version 2 holds the post while an admin may add it; version 3 drops it.
      # Two updaters: the archive merges one updater's edits within an hour.
      as(@admin) { @pool.update!(post_ids: [@live.id, @deleted.id]) }
      as(@member) { @pool.update!(post_ids: [@live.id]) }
      version = @pool.versions.find { |v| v.post_ids.include?(@deleted.id) }
      assert_not_nil version, "fixture: a version holds the deleted post"

      @pool.update_columns(name: "renamed_since")
      put_auth revert_pool_path(@pool), @member, params: { version_id: version.id }
      assert_response :redirect, response.body
      assert_equal [@live.id], @pool.reload.post_ids, "the hidden post was not seated"
      assert_equal version.name, @pool.name, "the rest of the version was restored"
      assert_match(/1 post in that version no longer exists for you and was left out/, flash[:notice])
      assert_no_match(/#{@deleted.id}/, flash[:notice])

      # An admin, who sees the ordinary deletion, restores it.
      RateLimit.delete_all
      put_auth revert_pool_path(@pool), @admin, params: { version_id: version.id }
      assert_equal [@live.id, @deleted.id], @pool.reload.post_ids
    end

    should "say, not drop, a newpool: the new pool refuses" do
      post = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }

      as(@uploader) { post.update(tag_string: "landscape newpool:#{"x" * 200}") }

      assert_nil Pool.find_by_name("x" * 200)
      assert_match(/Couldn't create pool x+: /, post.warnings.full_messages.join("\n"))
    end

    should "say, not drop, a pool:N the pool refuses" do
      full = as(@member) { create(:pool) }
      full.update_columns(post_ids: (1..Pool::MAX_POST_COUNT).map(&:-@))
      post = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }

      as(@uploader) { post.update(tag_string: "landscape pool:#{full.id}") }

      assert_not_includes full.reload.post_ids, post.id
      assert_match(/Couldn't add to pool ##{full.id}/, post.warnings.full_messages.join("\n"))
    end

    # R1: a revert takes out what the version lacks, and taking out a member
    # hidden from the reverter is a write on a post that does not exist for
    # them. It stays, as an edit keeps it (review 2026-11-20).
    # A hidden member the editor names all the same -- moved, or sent back
    # exactly where it is -- answers as a hidden non-member does, so the
    # answer never says it is a member, and it does not move (review
    # 2026-11-20).
    should "refuse a hidden member the editor names, as it refuses a hidden non-member" do
      kept = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@member) { @pool.update!(post_ids: [@live.id, kept.id]) }
      kept.delete!("duplicate", user: @admin)
      assert kept.reload.hidden_from?(@member), "fixture: the member is hidden from the editor"

      answers = [[kept.id, @live.id], [@live.id, kept.id], [@live.id, @deleted.id]].map do |list|
        RateLimit.delete_all
        put_auth pool_path(@pool, format: :json), @member, params: { pool: { post_ids: list }}
        assert_response 422, "#{list}: #{response.body}"
        assert_equal [@live.id, kept.id], @pool.reload.post_ids, "#{list} moved the pool"
        response.body.gsub(/\b(#{kept.id}|#{@deleted.id})\b/, "N")
      end
      assert_equal 1, answers.uniq.size, "a hidden member answered apart from a hidden non-member: #{answers.uniq}"

      RateLimit.delete_all
      put_auth pool_path(@pool, format: :json), @member, params: { pool: { name: "renamed_r1_pool" }}
      assert_response :success, "control: an edit naming no list leaves the hidden member be: #{response.body}"
      assert_equal [@live.id, kept.id], @pool.reload.post_ids
    end

    should "refuse a hidden member named in a favorite group edit, as a hidden non-member" do
      kept = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      group = as(@member) { create(:favorite_group, creator: @member, post_ids: [@live.id, kept.id]) }
      kept.delete!("duplicate", user: @admin)
      assert kept.reload.hidden_from?(@member), "fixture: the member is hidden from the creator"

      answers = [[kept.id, @live.id], [@live.id, kept.id], [@live.id, @deleted.id]].map do |list|
        RateLimit.delete_all
        put_auth favorite_group_path(group, format: :json), @member, params: { favorite_group: { post_ids: list }}
        assert_response 422, "#{list}: #{response.body}"
        assert_equal [@live.id, kept.id], group.reload.post_ids, "#{list} moved the group"
        response.body.gsub(/\b(#{kept.id}|#{@deleted.id})\b/, "N")
      end
      assert_equal 1, answers.uniq.size, "a hidden member answered apart from a hidden non-member: #{answers.uniq}"
    end

    should "keep a current member now hidden from the reverter" do
      kept = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      version = @pool.versions.find { |v| v.post_ids == [@live.id] }
      assert_not_nil version, "fixture: a version holds only the live post"
      as(@admin) { @pool.update!(post_ids: [@live.id, kept.id]) }
      kept.delete!("duplicate", user: @admin)
      assert kept.reload.hidden_from?(@member), "fixture: hidden from the member"

      put_auth revert_pool_path(@pool), @member, params: { version_id: version.id }
      assert_response :redirect, response.body
      assert_equal [@live.id, kept.id], @pool.reload.post_ids

      # An admin, who sees it, reverts it out.
      RateLimit.delete_all
      put_auth revert_pool_path(@pool), @admin, params: { version_id: version.id }
      assert_equal [@live.id], @pool.reload.post_ids
    end

    should "say, not drop, a -pool: naming no pool" do
      saved = as(@member) { @live.update(tag_string: "landscape -pool:no_such_pool_r1") }

      assert saved, @live.errors.full_messages.join("; ")
      assert_match(/Couldn't remove from pool no_such_pool_r1: no pool has that name or id/, @live.warnings.full_messages.join("\n"))
    end

    should "say, not drop, a -pool:N the deleted pool refuses, and let a builder take the post out" do
      @pool.update_columns(is_deleted: true)

      as(@member) { @live.update(tag_string: "landscape -pool:#{@pool.id}") }
      assert_includes @pool.reload.post_ids, @live.id
      assert_match(/Couldn't remove from pool ##{@pool.id}: You cannot update pools that are deleted/, @live.warnings.full_messages.join("\n"))

      post = Post.find(@live.id)
      as(@uploader) { post.update(tag_string: "landscape -pool:#{@pool.id}") }
      assert_not_includes @pool.reload.post_ids, @live.id, "a builder may update a deleted pool"
      assert_empty post.warnings.full_messages.grep(/Couldn't remove from pool/)
    end
  end
end
