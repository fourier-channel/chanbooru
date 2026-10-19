require "test_helper"

class BulkUpdateRequest::PrunerTest < ActiveSupport::TestCase
  context "#warn_old" do
    should "update the forum topic for a bulk update request" do
      bur = create(:bulk_update_request, status: "pending", created_at: (BulkUpdateRequest::Pruner::EXPIRATION_PERIOD - 1.day).ago)

      BulkUpdateRequest::Pruner.warn_old
      assert_equal("pending", bur.reload.status)
      assert_match(/pending automatic rejection/, ForumPost.last.body)
    end
  end

  context "#reject_expired" do
    should "reject the bulk update request" do
      bur = create(:bulk_update_request, status: "pending", created_at: (BulkUpdateRequest::Pruner::EXPIRATION_PERIOD + 1.day).ago)

      BulkUpdateRequest::Pruner.reject_expired
      assert_equal("rejected", bur.reload.status)
      assert_match(/rejected because it was not approved within \d+ days/, ForumPost.second.body)
    end
  end

  # Fork: a request filed while the forum is retired has no topic to be
  # warned in, and nothing else warns: it expires on time, silently -- it
  # reads rejected, which an admin may still approve -- and nothing is
  # written to the forum.
  context "a request with no forum topic" do
    should "expire on time, unwarned, and write nothing to the forum" do
      Danbooru.config.stubs(:retired_sections).returns(%w[forum_topics forum_posts forum_post_votes forum_topic_visits])
      old = create(:bulk_update_request, status: "pending", created_at: (BulkUpdateRequest::Pruner::EXPIRATION_PERIOD - 1.day).ago)
      expired = create(:bulk_update_request, status: "pending", created_at: (BulkUpdateRequest::Pruner::EXPIRATION_PERIOD + 1.day).ago)
      assert_nil(old.forum_topic)
      assert_nil(expired.forum_topic)

      assert_no_difference(["ForumTopic.count", "ForumPost.count"]) do
        BulkUpdateRequest::Pruner.warn_old
        BulkUpdateRequest::Pruner.reject_expired
      end

      assert_equal("pending", old.reload.status)
      assert_equal("rejected", expired.reload.status)
    end
  end
end
