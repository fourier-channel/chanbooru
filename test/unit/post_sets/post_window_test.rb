# frozen_string_literal: true

require "test_helper"

# PostSets::Post for the Modulation gallery window (GALLERY_WINDOW.md section
# 2): a chunk of the search from a cursor, sized by the window and not by the
# account's posts-per-page, with deleted posts dropped in the query so every
# cursor names a post that was drawn.
module PostSets
  class PostWindowTest < ActiveSupport::TestCase
    setup do
      @member = create(:user, per_page: 100)
      CurrentUser.user = @member
      @posts = create_list(:post, 5, tag_string: "wintest")
      @ids = @posts.map(&:id).sort.reverse
    end

    teardown do
      CurrentUser.user = nil
    end

    def set(tags = "wintest", page: nil, limit: nil, user: @member, window: :page, **cursors)
      PostSets::Post.new(tags, page, limit, user: user, window: window, **cursors)
    end

    context "the gallery window" do
      should "refuse a cursor it cannot keep" do
        assert_raises(PostNeighbors::NoPlace) { set(anchor: @ids[1].to_s, before: @ids[3].to_s).posts }
        assert_raises(PostNeighbors::NoPlace) { set("wintest order:random", anchor: @ids[1].to_s).posts }
        assert_raises(PostNeighbors::NoPlace) { set("wintest order:none", before: @ids[1].to_s).posts }
      end

      should "size the gallery by the window, not the account or limit:" do
        assert_equal 40, set.per_page
        assert_equal 40, set("wintest limit:7").per_page
        assert_equal 40, set(window: :chunk).per_page
        assert_equal 70, set(window: :chunk, limit: 70).per_page
        assert_equal 100, set(window: :chunk, limit: 5000).per_page
        assert_equal 40, set(window: :chunk, limit: 3).per_page
        assert_equal 100, set(window: nil).per_page, "outside the gallery the account still sizes the page"
        assert_equal Danbooru.config.restricted_browsing_per_page.to_i, set(user: create(:restricted_user)).per_page
      end

      should "give a restricted viewer no cursor" do
        restricted = create(:restricted_user)
        assert_raises(PaginationExtension::PaginationError) { set(user: restricted, anchor: @ids[1].to_s).posts }
        assert_raises(PaginationExtension::PaginationError) { set(user: restricted, before: @ids[1].to_s).posts }
        assert_not set(user: restricted).windowing?
      end

      should "page from an anchor, inclusive, and before one, exclusive" do
        assert_equal @ids[1..], set(anchor: @ids[1].to_s).posts.map(&:id)
        assert_equal @ids[0..1], set(window: :chunk, before: @ids[2].to_s).posts.map(&:id)
      end

      should "say what lies on either side" do
        head = set
        assert_not head.window_more_behind?
        assert_not head.window_more_ahead?
        later = set(anchor: @ids[2].to_s)
        assert later.window_more_behind?
        assert_nil later.window_prev_cursor, "fewer than 20 behind: prev goes to the head"
      end

      should "carry each card's cursor" do
        cursors = set("wintest order:score").window_cursors
        assert_equal @posts.to_h { |post| [post.id, PostNeighbors::Seek.mint(post, "score")] }, cursors
        assert_equal(%w[@0 @1 @2], set("wintest order:comment_bumped").window_cursors.values.first(3))
      end

      should "walk past a run of deleted posts longer than a chunk" do
        deleted = create_list(:post, PostSets::Post::WINDOW_CHUNK_MAX + 1, tag_string: "wintest")
        ::Post.where(id: deleted.map(&:id)).update_all(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations
        # The cursor names a deleted post, by its key: it keeps its place.
        newest = deleted.map(&:id).max
        chunk = set(window: :chunk, anchor: "#{newest}~#{newest}", limit: PostSets::Post::WINDOW_CHUNK_MAX)
        assert_equal @ids, chunk.posts.map(&:id), "the drawn posts on the far side of the deleted run"
        assert_not chunk.window_more_ahead?
        @member.update!(show_deleted_posts: true)
        shown = set(window: :chunk, anchor: "#{newest}~#{newest}", limit: PostSets::Post::WINDOW_CHUNK_MAX)
        assert_equal deleted.map(&:id).sort.reverse.first(PostSets::Post::WINDOW_CHUNK_MAX), shown.posts.map(&:id), "a viewer who asked for deleted posts walks them"
      end

      should "refuse a bare anchor the same way for every post this search does not hold" do
        Danbooru.config.stubs(:restricted_tags).returns(["wingated"])
        gated = create(:post, tag_string: "wintest wingated")
        deleted = create(:post, tag_string: "wintest", is_deleted: true)
        outside = create(:post, tag_string: "elsewhere")
        messages = [gated.id, deleted.id, outside.id, 999_999_999].map do |id|
          assert_raises(PostNeighbors::NoPlace) { set("wintest order:score", anchor: id.to_s).posts }.message
        end
        assert_equal 1, messages.uniq.size, messages.inspect
        assert_equal @posts.max_by { [it.score, it.id] }.id, set("wintest order:score", anchor: @ids[0].to_s).posts.first.id
      end

      should "read an old page=N as the position it showed" do
        assert_equal set(anchor: "@40").posts.map(&:id), set(page: 3).posts.map(&:id)
        more = create_list(:post, 45, tag_string: "wintest").map(&:id).sort.reverse # rubocop:disable FactoryBot/ExcessiveCreateList
        all = more + @ids
        assert_equal all[40..79], set(page: 3).posts.map(&:id)
      end

      should "serve an id-cursor page as it always was, outside the window" do
        legacy = set(page: "b#{@ids[1]}")
        assert_not legacy.windowing?
        assert_equal @ids[2..], legacy.posts.map(&:id)
        assert_equal 20, legacy.per_page
      end
    end
  end
end
