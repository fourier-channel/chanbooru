# frozen_string_literal: true

# Two sorts the gallery offers in its dropdown could not be served, and a third
# still cannot.
#
# Measured 2026-09-12 over the real request path, on the post index:
#
#     order:id          200   0.23 s   served by posts_pkey
#     order:created_at  200   1.23 s   served by index_posts_on_created_at
#     order:id_desc     200   1.59 s   served by posts_pkey
#     order:score       500   3.10 s   TIMED OUT
#     order:favcount    500   4.15 s   TIMED OUT
#     order:random      500   4.08 s   TIMED OUT
#
# `posts` carried indexes on created_at and on the primary key and NOTHING on
# score or fav_count, so those two planned a parallel sequential scan with a
# top-N heapsort across every row -- 17,147 buffers read from disk for twenty
# results. Ordinary users get a 3,000 ms statement budget (User.statement_timeout:
# 3s below Gold, 6s at Gold, 9s at Platinum and above), so the query was
# refused and the viewer got the Search Timeout page. Both failed with a tag
# attached as well, which is the common case: `1girl order:score` timed out too.
#
# DESC NULLS LAST matches how the sorts are actually issued, so the index can be
# read in order rather than sorted after the fact.
#
# CONCURRENTLY because this table is live and a plain CREATE INDEX takes a lock
# that blocks writes for the duration -- the sampler is posting continuously.
# That forces disable_ddl_transaction!, since CREATE INDEX CONCURRENTLY cannot
# run inside a transaction block. The cost of that choice is that a failure
# leaves an INVALID index behind rather than rolling back, so if this migration
# ever fails, drop the invalid index before re-running it:
#
#     SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
#
# NOT FIXED HERE: `order:random`. No index can serve ORDER BY random(), because
# the ordering key is invented per row at query time. It needs a different
# implementation (a sampled offset, or TABLESAMPLE), which is a behaviour change
# rather than an index, so it is left alone and recorded instead of quietly
# half-addressed.
class IndexPostsForScoreAndFavcountSorts < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_index :posts, :score, order: { score: "DESC NULLS LAST" },
              name: "index_posts_on_score_desc", algorithm: :concurrently,
              if_not_exists: true
    add_index :posts, :fav_count, order: { fav_count: "DESC NULLS LAST" },
              name: "index_posts_on_fav_count_desc", algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :posts, name: "index_posts_on_score_desc",
                 algorithm: :concurrently, if_exists: true
    remove_index :posts, name: "index_posts_on_fav_count_desc",
                 algorithm: :concurrently, if_exists: true
  end
end
