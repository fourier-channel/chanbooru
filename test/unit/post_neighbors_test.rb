# frozen_string_literal: true

require "test_helper"

class PostNeighborsTest < ActiveSupport::TestCase
  # The engine's prev/next must match adjacency in the list Danbooru itself
  # builds for that order (order_matches). Validates the keyset seek against the
  # real ordering for every covered sort. (Class-level so `should` blocks see it.)
  def assert_matches_ordering(order)
    search = "status:any order:#{order}"
    ordered = Post.user_tag_match(search, @user).to_a
    ordered.each_with_index do |post, idx|
      nav = PostNeighbors.new(post: post, tags: search, user: @user)
      expected_prev = idx.positive? ? ordered[idx - 1].id : nil
      expected_next = (idx < ordered.size - 1) ? ordered[idx + 1].id : nil
      assert_equal expected_prev, nav.prev_id, "prev of ##{post.id} in order:#{order}" if expected_prev
      assert_nil nav.prev_id, "prev of first ##{post.id} in order:#{order}" if expected_prev.nil?
      assert_equal expected_next, nav.next_id, "next of ##{post.id} in order:#{order}" if expected_next
      assert_nil nav.next_id, "next of last ##{post.id} in order:#{order}" if expected_next.nil?
    end
  end

  context "PostNeighbors" do
    setup do
      @user = create(:user)
      CurrentUser.user = @user
      # Distinct id, created_at, score, fav_count, tag_count so no sort has ties
      # (equal keys would make the DB tiebreak ambiguous against the keyset's).
      @posts = (0...6).map do |i|
        travel_to((30 - i * 2).days.ago) do
          # Distinct tag NAMES so tag_count (distinct-tag count) is distinct per post.
          create(:post, score: i * 7, fav_count: i * 3, tag_string: (0..i).map { |j| "tag#{j}" }.join(" "))
        end
      end
    end

    teardown do
      CurrentUser.user = nil
    end

    should "match the built ordering across id/date/score/favcount/change/tagcount sorts" do
      %w[id id_desc created_at created_at_asc score score_asc favcount favcount_asc change change_asc tagcount tagcount_asc].each do |order|
        assert_matches_ordering(order)
      end
    end

    should "default to id_desc when the query has no order" do
      nav = PostNeighbors.new(post: @posts[3], tags: "status:any", user: @user)
      assert_equal "id_desc", nav.order
      # id_desc renders newest-first, so prev (←) is the newer post and next (→)
      # is the older one.
      assert_equal @posts[4].id, nav.prev_id
      assert_equal @posts[2].id, nav.next_id
    end

    should "return nil at the ends of the sequence" do
      ordered = Post.user_tag_match("status:any order:id_desc", @user).to_a
      assert_nil PostNeighbors.new(post: ordered.first, tags: "order:id_desc", user: @user).prev_id
      assert_nil PostNeighbors.new(post: ordered.last, tags: "order:id_desc", user: @user).next_id
    end

    should "draw neighbours only from the filtered set (same-artist gallery style)" do
      # Only even-indexed posts carry the "b" tag; neighbours must skip the rest.
      @posts.each_with_index { |p, i| p.update!(tag_string: "#{p.tag_string} b") if i.even? }
      subset = [@posts[0], @posts[2], @posts[4]]
      nav = PostNeighbors.new(post: @posts[2], tags: "b order:id_asc", user: @user)
      assert_equal subset[0].id, nav.prev_id
      assert_equal subset[2].id, nav.next_id
    end

    should "fall back to the id walk for an unsupported order (random)" do
      nav = PostNeighbors.new(post: @posts[3], tags: "status:any order:random", user: @user)
      # random isn't keyset-able; fall back to id walk (prev = newer, next = older).
      assert_equal @posts[4].id, nav.prev_id
      assert_equal @posts[2].id, nav.next_id
    end
  end
end
