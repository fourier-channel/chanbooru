# frozen_string_literal: true

require "test_helper"

# A GALLERY SORTED order:random -- THE MD5 SEEK ON A LARGE SEARCH.
#
# The Modulation gallery's sort menu offers "random", the panel REMEMBERS a
# viewer's sort and re-applies it to every later search, and order:random was
# ORDER BY random() over the whole search. On production data (2026-09-26)
# that was 2.1-2.6s a page for a 280-300k-post tag with the table in cache,
# and tens of seconds when the box's disk is busy (a cold full scan of the
# posts table measured 44s). Danbooru's own Post.random -- the random:N
# metatag, and the gallery's Random button -- was 6-71ms for the same
# searches.
#
# But Post.random is biased on a SMALL search: on a 24-post tag even 200
# draws found only 12 posts, while ORDER BY random() there took 6ms. So the
# sort stays a true shuffle up to a ceiling and is sampled beyond it, or when
# the search was too slow to count. Every sampled page is a fresh sample: page
# 3 of a random order was already just another random draw.
class RandomOrderPaginationTest < ActiveSupport::TestCase
  # Every statement Active Record sends while the block runs.
  def statements
    sqls = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sqls << payload[:sql] }
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # A count past the ceiling. The search itself holds six posts: the COUNT the
  # paginator is handed is what decides which path a search takes.
  LARGE = PostQueryBuilder::RANDOM_SORT_CEILING + 1

  def whole_search_sorts(sqls)
    sqls.select { |s| s.match?(/ORDER BY random\(\)/i) && s.exclude?("random_md5s") }
  end

  context "A search sorted order:random" do
    setup do
      @user = create(:user)
      @posts = create_list(:post, 6)
    end

    should "sample a search larger than the ceiling by the md5 seek, and fill every page" do
      as(@user) do
        page = nil
        sqls = statements do
          page = PostQuery.new("order:random", current_user: @user).paginated_posts(3, count: LARGE, limit: 2).to_a
        end

        assert_empty(whole_search_sorts(sqls), "a large search was sorted whole by random()")
        assert(sqls.any? { |s| s.include?("random_md5s") }, "no md5 seek ran")
        # Up to the page size, never empty: page 3 of a random order is another
        # random page. (Draws can collide, so six posts cannot promise two.)
        assert_includes(1..2, page.size, "page 3 of a random order came back #{page.size} posts")
        assert((page.map(&:id) - @posts.map(&:id)).empty?)
      end
    end

    should "keep the page it was asked for, for the pager" do
      as(@user) do
        page = PostQuery.new("order:random", current_user: @user).paginated_posts(3, count: LARGE, limit: 2)
        assert_equal(3, page.current_page)
      end
    end

    should "treat a search too slow to count as large" do
      as(@user) do
        sqls = statements { PostQuery.new("order:random", current_user: @user).paginated_posts(1, count: nil, limit: 2).to_a }
        assert(sqls.any? { |s| s.include?("random_md5s") }, "an uncounted search was sorted whole")
      end
    end

    should "shuffle a search within the ceiling exactly -- every post, sorted by random()" do
      as(@user) do
        page = nil
        sqls = statements do
          page = PostQuery.new("order:random", current_user: @user).paginated_posts(1, count: 6, limit: 10).to_a
        end

        assert_not_empty(whole_search_sorts(sqls), "a small search should keep its true shuffle")
        assert_equal(@posts.map(&:id).sort, page.map(&:id).sort)
      end
    end
  end
end
