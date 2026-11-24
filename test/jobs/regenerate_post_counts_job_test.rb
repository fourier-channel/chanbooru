require "test_helper"

class RegeneratePostCountsJobTest < ActiveJob::TestCase
  # A second database session: the job's own would be granted its own lock.
  def in_another_session
    conn = PG.connect(Tag.connection.raw_connection.conninfo_hash.compact)
    yield conn
  ensure
    conn&.close
  end

  # Asked, never waited for, and given back before the session closes: its
  # end frees the lock too, but some time after the close returns.
  def take_lock(conn)
    conn.exec("SELECT pg_try_advisory_lock(#{Tag::POST_COUNT_LOCK}) AS got").first["got"] == "t"
  end

  def give_back(conn)
    conn.exec("SELECT pg_advisory_unlock(#{Tag::POST_COUNT_LOCK})")
  end

  def lock_free?
    in_another_session { |conn| take_lock(conn) && give_back(conn).present? }
  end

  def counts(*names)
    names.map { |name| Tag.find_by_name!(name).post_count }
  end

  context "RegeneratePostCountsJob" do
    should "regenerate all incorrect tag post counts" do
      create(:tag, name: "touhou", post_count: -10)
      create(:tag, name: "bkub", post_count: 10)
      create(:tag, name: "chen", post_count: 10)
      create(:post, tag_string: "touhou bkub")

      RegeneratePostCountsJob.perform_now

      assert_equal(1, Tag.find_by_name!("touhou").post_count)
      assert_equal(1, Tag.find_by_name!("bkub").post_count)
      assert_equal(0, Tag.find_by_name!("chen").post_count)
    end

    should "return only the tags that were wrong, as corrected" do
      create(:tag, name: "chen", post_count: 10)
      create(:post, tag_string: "touhou")
      right = Tag.find_by_name!("touhou").updated_at

      assert_equal([["chen", 0]], Tag.regenerate_post_counts!.map { |tag| [tag.name, tag.post_count] })
      assert_equal(right, Tag.find_by_name!("touhou").updated_at)
      assert_empty(Tag.regenerate_post_counts!)
    end

    # The count takes half a minute, and uploads do not stop for it. Writing
    # the counted number would take touhou back to 1 and lose the upload's.
    should "keep a count raised between the count and the correction" do
      create(:post, tag_string: "touhou bkub")
      Tag.where(name: "touhou").update_all(post_count: 7)
      wrong = Tag.wrong_post_counts
      create(:post, tag_string: "touhou bkub")
      Tag.stubs(:wrong_post_counts).returns(wrong)

      RegeneratePostCountsJob.perform_now

      assert_equal([2, 2], counts("touhou", "bkub"))
    end

    should "do nothing while another recount holds the lock" do
      create(:tag, name: "chen", post_count: 10)

      in_another_session do |conn|
        assert(take_lock(conn))
        RegeneratePostCountsJob.perform_now
        assert_equal([10], counts("chen"))
        give_back(conn)
      end

      RegeneratePostCountsJob.perform_now
      assert_equal([0], counts("chen"))
    end

    should "leave the lock free behind it, and when it fails" do
      RegeneratePostCountsJob.perform_now
      assert(lock_free?, "the lock outlived the run")

      Tag.stubs(:wrong_post_counts).raises(RuntimeError, "the count failed")
      assert_raises(RuntimeError) { Tag.regenerate_post_counts! }
      assert(lock_free?, "the lock outlived a failed run")
    end

    should "hold the lock while it counts" do
      free = nil
      Tag.stubs(:wrong_post_counts).with do
        free = lock_free?
        true
      end.returns([])

      Tag.regenerate_post_counts!
      assert_equal(false, free)
    end
  end
end
