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

  # The flank candidates (run): the DEPTH posts either side of each post are
  # the next and previous DEPTH rows of the same built ordering, nearest
  # first, and `more` says whether a row lies past them.
  def assert_run_matches_ordering(order, depth)
    search = "status:any order:#{order}"
    ordered = Post.user_tag_match(search, @user).to_a
    ordered.each_with_index do |post, idx|
      nav = PostNeighbors.new(post: post, tags: search, user: @user)
      after = ordered[(idx + 1)..]
      before = ordered[0...idx].reverse
      nxt = nav.run(:next, depth)
      prv = nav.run(:prev, depth)
      assert_equal after.first(depth).map(&:id), nxt[:ids], "next #{depth} of ##{post.id} in order:#{order}"
      assert_equal before.first(depth).map(&:id), prv[:ids], "prev #{depth} of ##{post.id} in order:#{order}"
      assert_equal after.size > depth, nxt[:more], "next more of ##{post.id} in order:#{order}"
      assert_equal before.size > depth, prv[:more], "prev more of ##{post.id} in order:#{order}"
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
      # id_desc renders newest-first, so prev (<-) is the newer post and next (->)
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

    context "run, the flank candidates" do
      setup do
        # Ten posts: more than DEPTH either side of the middle ones, so `more`
        # is exercised both ways. Distinct file sizes and pixel counts, as the
        # other sorts' keys are distinct: order:filesize has no id tiebreak.
        @posts += (6...10).map do |i|
          travel_to((30 - (i * 2)).days.ago) do
            create(:post, score: i * 7, fav_count: i * 3, tag_string: (0..i).map { |j| "tag#{j}" }.join(" "))
          end
        end
        @posts.each_with_index do |post, i|
          post.media_asset.update_columns(file_size: 1000 + ((i * 37 % 10) * 100), image_width: 100 + (i * 3 % 10), image_height: 100) # rubocop:disable Rails/SkipsModelValidations -- fixture keys only
        end
      end

      should "give the next and previous DEPTH rows of the built ordering for every keyset sort" do
        assert_equal 6, PostNeighbors::DEPTH
        %w[id id_desc created_at created_at_asc score score_asc favcount favcount_asc change change_asc tagcount tagcount_asc filesize filesize_asc mpixels mpixels_asc].each do |order|
          assert_run_matches_ordering(order, PostNeighbors::DEPTH)
        end
      end

      should "honour the depth on the id-walk fallback (random, and a post with no sort key)" do
        assert_run_matches_ordering("id_desc", 3)
        nav = PostNeighbors.new(post: @posts[5], tags: "status:any order:random", user: @user)
        assert_equal @posts[6..8].map(&:id), nav.run(:prev, 3)[:ids]
        assert_equal @posts[2..4].reverse.map(&:id), nav.run(:next, 3)[:ids]

        # A post with no media asset has no filesize key: the id walk again.
        @posts[5].stubs(:media_asset).returns(nil)
        nav = PostNeighbors.new(post: @posts[5], tags: "status:any order:filesize", user: @user)
        assert_equal @posts[2..4].reverse.map(&:id), nav.run(:next, 3)[:ids]
        assert nav.run(:next, 3)[:more]
      end

      # `exactly K remain` is not `more`.
      should "say more exactly" do
        ordered = Post.user_tag_match("status:any order:id_desc", @user).to_a
        at = ->(i) { PostNeighbors.new(post: ordered[i], tags: "order:id_desc", user: @user) }
        six_after = ordered.size - 7
        assert_equal({ ids: ordered[(six_after + 1)..].map(&:id), more: false }, at.call(six_after).run(:next, 6))
        assert_equal({ ids: ordered[(six_after)..(six_after + 5)].map(&:id), more: true }, at.call(six_after - 1).run(:next, 6))
        assert_equal({ ids: [], more: false }, at.call(ordered.size - 1).run(:next, 6))
        assert_equal({ ids: [], more: false }, at.call(0).run(:prev, 6))
      end

      should "agree with next_id and prev_id at depth 1" do
        ordered = Post.user_tag_match("status:any order:score", @user).to_a
        ordered.each do |post|
          nav = PostNeighbors.new(post: post, tags: "status:any order:score", user: @user)
          assert_equal [nav.next_id].compact, nav.run(:next, 1)[:ids]
          assert_equal [nav.prev_id].compact, nav.run(:prev, 1)[:ids]
        end
      end

      # One keyset seek per side however deep: a per-candidate lookup creeping
      # in would multiply every post view's neighbour cost by DEPTH. (Building
      # the search itself may ask a fixed question or two first; that count
      # must not move with the depth either.)
      should "issue one keyset query per side, fetching DEPTH + 1 rows" do
        capture = lambda do |dir, depth|
          seen = []
          nav = PostNeighbors.new(post: @posts[5], tags: "status:any order:filesize", user: @user)
          sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            seen << [payload[:sql], Array(payload[:type_casted_binds]).map { it.respond_to?(:value) ? it.value : it }] unless payload[:name] == "SCHEMA"
          end
          nav.run(dir, depth)
          ActiveSupport::Notifications.unsubscribe(sub)
          seen
        end

        capture.call(:next, 1) # warm the per-process caches the search reads
        %i[next prev].each do |dir|
          deep = capture.call(dir, PostNeighbors::DEPTH)
          assert_equal capture.call(dir, 1).size, deep.size, "statements at depth 1 vs #{PostNeighbors::DEPTH}"
          seeks = deep.select { |sql, _| sql.include?('FROM "posts"') && sql.include?("ORDER BY") }
          assert_equal 1, seeks.size, seeks.map(&:first).join("\n")
          sql, binds = seeks.first
          limit = sql[/LIMIT (\d+)/, 1] || binds.last
          assert_equal PostNeighbors::DEPTH + 1, limit.to_i, sql
        end
      end
    end

    should "fall back to the id walk for an unsupported order (random)" do
      nav = PostNeighbors.new(post: @posts[3], tags: "status:any order:random", user: @user)
      # random isn't keyset-able; fall back to id walk (prev = newer, next = older).
      assert_equal @posts[4].id, nav.prev_id
      assert_equal @posts[2].id, nav.next_id
    end
  end
end
