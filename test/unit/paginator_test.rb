require "test_helper"

class PaginatorTest < ActiveSupport::TestCase
  # A full account: these measure the paginator's own mechanics, which the
  # browsing tier (browsing_tier_test.rb) bounds for a viewer below it.
  setup do
    @posts = create_list(:post, 5)
    CurrentUser.user = create(:user)
  end

  teardown do
    CurrentUser.user = nil
  end

  context "sequential pagination (before)" do
    should "return the correct set of records" do
      expected_posts = Post.limit(3).order(id: :desc)
      posts = Post.paginate("b9999999", limit: 3)

      assert_equal(expected_posts.map(&:id), posts.map(&:id))
    end

    should "return nothing for b0" do
      posts = Post.paginate("b0")
      assert_empty(posts.map(&:id))
    end
  end

  context "sequential pagination (after)" do
    should "return the correct set of records" do
      expected_posts = Post.limit(3).order(id: :asc).reverse
      posts = Post.paginate("a0", limit: 3)

      assert_equal(expected_posts.map(&:id), posts.map(&:id))
    end
  end

  # The gallery window's mode (PostNeighbors::Seek): a chunk from a cursor,
  # one row more than asked for, so `more?` is exact.
  context "seek pagination" do
    setup do
      @ids = @posts.map(&:id).sort.reverse
    end

    should "trim to the limit going forward, saying more only with an extra row" do
      chunk = Post.paginate(nil, limit: 3, seek: PostNeighbors::Seek.head("id_desc"))
      assert_equal(@ids.first(3), chunk.map(&:id))
      assert_equal(true, chunk.more?)

      assert_equal(false, Post.paginate(nil, limit: 5, seek: PostNeighbors::Seek.head("id_desc")).more?, "exactly the last page")
      assert_equal(false, Post.paginate(nil, limit: 6, seek: PostNeighbors::Seek.head("id_desc")).more?)
    end

    should "come out in display order going backward" do
      seek = PostNeighbors::Seek.parse("id_desc", @ids[4].to_s, direction: :backward)
      chunk = Post.paginate(nil, limit: 2, seek: seek)
      assert_equal(@ids[2..3], chunk.map(&:id))
      assert_equal(true, chunk.more?)
      assert_equal(false, Post.paginate(nil, limit: 4, seek: seek).more?)
    end
  end

  context "numbered pagination" do
    should "return the correct set of records" do
      expected_posts = Post.limit(3).order(id: :desc)
      posts = Post.order(id: :desc).paginate("1", limit: 3)

      assert_equal(expected_posts.map(&:id), posts.map(&:id))
    end

    should "raise an error when exceeding the page limit" do
      assert_raises(PaginationExtension::PaginationError) do
        Post.paginate(10, page_limit: 5)
      end
    end

    should "count pages correctly" do
      assert_equal(5, Post.paginate(1, limit: 1).total_pages)
      assert_equal(3, Post.paginate(1, limit: 2).total_pages)
      assert_equal(2, Post.paginate(1, limit: 3).total_pages)
      assert_equal(2, Post.paginate(1, limit: 4).total_pages)
      assert_equal(1, Post.paginate(1, limit: 5).total_pages)
    end

    should "detect the first and last page correctly" do
      assert_equal(true, Post.paginate(0, limit: 1).is_first_page?)
      assert_equal(true, Post.paginate(1, limit: 1).is_first_page?)
      assert_equal(false, Post.paginate(1, limit: 1).is_last_page?)

      assert_equal(false, Post.paginate(5, limit: 1).is_first_page?)
      assert_equal(true, Post.paginate(5, limit: 1).is_last_page?)
      assert_equal(true, Post.paginate(6, limit: 1).is_last_page?)
    end
  end

  # THE LAST ALLOWED PAGE (ACCOUNT_LIMITS.md 2.0). paginate switched to
  # sequential_after mode on page == page_limit while still building numbered
  # SQL, and #records reverses that mode's rows: the page came out backward,
  # with no current_page and a "next" pointing back into itself. Upstream hits
  # it for a Member on exactly page 1000; a one-page tier hits it on page 1.
  context "the last page a viewer may reach" do
    setup do
      create_list(:post, 2)
    end

    should "list the same rows in the same order as that page under a higher limit" do
      numbered = Post.order(id: :desc).paginate(3, limit: 2, page_limit: 4)
      last = Post.order(id: :desc).paginate(3, limit: 2, page_limit: 3)

      assert_equal(2, numbered.size, "fixture: page 3 holds two rows, so a reversal shows")
      assert_equal(numbered.map(&:id), last.map(&:id))
      assert_equal(:numbered, last.paginator_mode)
      assert_equal(3, last.current_page)
    end

    should "go back by number, and on only by a cursor for a viewer who may use one" do
      last = Post.order(id: :desc).paginate(3, limit: 2, page_limit: 3)

      assert_equal(2, last.prev_page)
      assert_equal("b#{last.records.last.id}", last.next_page)
    end
  end
end
