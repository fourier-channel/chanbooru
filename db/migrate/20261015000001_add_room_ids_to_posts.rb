# frozen_string_literal: true

# GATE 3 FOR POSTS: every post carries the rooms its image counts in
# (fourier-basis docs/design/GATE3_MATRIX_POSTS.md, piece D).
#
#   {0}  a post with no mxc of its own -- every viewer's set holds 0;
#   {..} a Matrix post: the union of its mxcs' rooms, plus -1 for a site asset;
#   {}   a Matrix post none of whose mxcs fourier-auth has answered for yet --
#        shown to nobody but the pipeline (fail closed) once the gate is on.
#
# NO INDEX on room_ids, on purpose (measured 2026-10-15 at 1.14M ordinary +
# 1M Matrix posts in 10k rooms): with a GIN index the planner, unable to see
# the viewer's list at plan time, BitmapAnds a condition matching most of the
# table -- 113 s for a viewer in 5,000 rooms. Without one, every page query
# stays at a few milliseconds.
#
# The column is added with a constant default (no table rewrite), then the
# existing mxc:// posts are mapped (post_mxcs, 'post_source') and closed
# ('{}'), in id ranges, each its own transaction, so no long lock is held on
# posts. Re-runnable: both steps skip what is already done.
class AddRoomIdsToPosts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH = 10_000

  def up
    add_column :posts, :room_ids, :integer, array: true, null: false, default: [0]
    seed!
  end

  def down
    remove_column :posts, :room_ids
  end

  def seed!
    max = select_value("SELECT coalesce(max(id), 0) FROM posts").to_i
    (0..max).step(BATCH) do |low|
      high = low + BATCH
      range = "id >= #{low} AND id < #{high} AND source LIKE 'mxc://%'"
      execute(<<~SQL.squish)
        INSERT INTO post_mxcs (post_id, mxc, source, created_at, updated_at)
        SELECT id, source, 'post_source', now(), now() FROM posts WHERE #{range}
        ON CONFLICT (mxc) DO NOTHING
      SQL
      execute("UPDATE posts SET room_ids = '{}' WHERE #{range} AND room_ids = '{0}'")
    end
  end
end
