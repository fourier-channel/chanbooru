# frozen_string_literal: true

# order:tagcount sorted the whole posts table: no index covered tag_count, so
# the gallery's "tagcount" sort over all posts took 176 s on production
# (2026-10-18, measured for the gallery window), past every statement timeout
# -- the sort was offered in the menu and answered with the search-timeout
# page. (tag_count, id) serves both the numbered order (posts.tag_count DESC)
# and the window's keyset (posts.tag_count DESC, posts.id DESC), read
# backwards for the ascending sorts. Concurrently, so production's table is
# not locked while it builds.
class IndexPostsOnTagCountAndId < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :posts, [:tag_count, :id], algorithm: :concurrently, name: "index_posts_on_tag_count_and_id"
  end
end
