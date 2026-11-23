# frozen_string_literal: true

# A post's ORIGINAL date: when the thing it was taken from was posted (the
# 4chan reply, the Discord message, the Matrix event), not when the booru
# received it. Archive ingest uploads years-old posts today, so posts.created_at
# and posts.id order them as the newest on the site; source_created_at is the
# order a reader means by "newest".
#
# source_created_at_precision says how it is known:
#   exact      -- the sender gave the source post's own time
#   estimated  -- interpolated between known neighbours (archive backfill)
#   added      -- nothing better is known; the booru's own created_at
#
# Nullable here and filled by a backfill; the next migration makes it NOT NULL
# and the default order. The index is built while every value is NULL, so it
# costs nothing now, and CONCURRENTLY so the posts table is never locked.
class AddSourceCreatedAtToPosts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :posts, :source_created_at, :datetime, if_not_exists: true
    add_column :posts, :source_created_at_precision, :string, if_not_exists: true
    add_index :posts, %i[source_created_at id], order: { source_created_at: :desc, id: :desc },
      name: "index_posts_on_source_created_at_and_id_desc", algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :posts, name: "index_posts_on_source_created_at_and_id_desc", algorithm: :concurrently, if_exists: true
    remove_column :posts, :source_created_at_precision, if_exists: true
    remove_column :posts, :source_created_at, if_exists: true
  end
end
