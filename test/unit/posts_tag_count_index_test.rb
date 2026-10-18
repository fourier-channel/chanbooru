# frozen_string_literal: true

require "test_helper"

# order:tagcount needs an index on posts.tag_count: without one the sort read
# the whole posts table (176 s on production, 2026-10-18). (tag_count, id)
# serves the numbered order and the gallery window's keyset alike.
class PostsTagCountIndexTest < ActiveSupport::TestCase
  should "index posts by tag count, then id" do
    assert ActiveRecord::Base.connection.index_exists?(:posts, [:tag_count, :id], name: "index_posts_on_tag_count_and_id")
  end
end
