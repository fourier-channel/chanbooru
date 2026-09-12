# frozen_string_literal: true

# Corrects 20260912120000, which added the right columns in the wrong order and
# therefore changed nothing at all. Kept as a separate migration rather than an
# edit to that one, because it already ran against production.
#
# WHAT WENT WRONG. The first version indexed `score DESC NULLS LAST` on its own,
# chosen from an EXPLAIN of `SELECT id FROM posts ORDER BY score DESC LIMIT 20`
# -- a query the application never issues. The real one, read out of the app
# rather than guessed, is:
#
#     SELECT posts.* FROM posts ORDER BY posts.score DESC, posts.id DESC LIMIT 20
#
# Two mismatches, either of which alone makes the index useless for ordering:
#
#   1. It sorts by TWO keys, score then id. A single-column index cannot supply
#      that order, so Postgres sorts anyway.
#   2. `DESC` in Postgres implies NULLS FIRST. The index declared NULLS LAST, a
#      different ordering, so it could not be walked to satisfy the query even
#      on the leading key. (Both columns are NOT NULL, so this distinction
#      changes no rows -- it still defeats the planner.)
#
# Measured on production, same query, three states:
#
#     no index                     parallel seq scan + top-N heapsort, cost 25,834
#     score DESC NULLS LAST        parallel seq scan + top-N heapsort, cost 25,896
#     score DESC, id DESC          Index Scan, cost 6.28, 0.157 ms
#
# The lesson is worth more than the index: the first version was validated
# against a query I wrote myself, which proved only that my own query was fast.
# The SQL the application issues is available from
# `PostQuery.normalize(...).posts.limit(20).to_sql`, and that is what any future
# index for this table should be built against.
#
# order:random is still not addressed and still cannot be, by any index. It is
# recorded in the previous migration's comment.
class CorrectTheScoreAndFavcountSortIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    remove_index :posts, name: "index_posts_on_score_desc",
                 algorithm: :concurrently, if_exists: true
    remove_index :posts, name: "index_posts_on_fav_count_desc",
                 algorithm: :concurrently, if_exists: true

    add_index :posts, [:score, :id], order: { score: :desc, id: :desc },
              name: "index_posts_on_score_and_id_desc",
              algorithm: :concurrently, if_not_exists: true
    add_index :posts, [:fav_count, :id], order: { fav_count: :desc, id: :desc },
              name: "index_posts_on_fav_count_and_id_desc",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :posts, name: "index_posts_on_score_and_id_desc",
                 algorithm: :concurrently, if_exists: true
    remove_index :posts, name: "index_posts_on_fav_count_and_id_desc",
                 algorithm: :concurrently, if_exists: true
  end
end
