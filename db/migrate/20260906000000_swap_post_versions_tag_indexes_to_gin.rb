# frozen_string_literal: true

class SwapPostVersionsTagIndexesToGin < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction.
  disable_ddl_transaction!

  # Declares, in the schema, a change that was made to production by hand.
  #
  # Upstream indexes post_versions.added_tags and removed_tags with btrees. A
  # btree row is capped at 2704 bytes, and this fork's autotagger writes
  # 300-500 tags per post, so any such post's version row overflowed the
  # index and the archives consumer crashed on insert -- 50,953 restarts
  # between 2026-08-25 and 2026-09-05 before anyone looked. GIN is the right
  # index for an array column and has no such cap.
  #
  # The swap was applied to the live database on 2026-09-05 (CREATE INDEX
  # CONCURRENTLY, verified valid, btrees dropped) and the loop ended within
  # thirty seconds. But structure.sql kept declaring the btrees, so a fresh
  # db:prepare on a new box would have rebuilt the bug faithfully. This
  # migration is what makes the fix survive the normal cycle (operator,
  # 2026-09-06: "if we have changes that won't persist through normal dev
  # cycle, that needs to be addressed").
  #
  # Every step is guarded, so on production -- where the end state already
  # holds -- this records its version and changes nothing.
  def up
    remove_index :post_versions, name: "index_post_versions_on_added_tags", if_exists: true, algorithm: :concurrently
    remove_index :post_versions, name: "index_post_versions_on_removed_tags", if_exists: true, algorithm: :concurrently
    add_index :post_versions, :added_tags, using: :gin, name: "index_post_versions_on_added_tags_gin", if_not_exists: true, algorithm: :concurrently
    add_index :post_versions, :removed_tags, using: :gin, name: "index_post_versions_on_removed_tags_gin", if_not_exists: true, algorithm: :concurrently
  end

  def down
    # The btrees ARE the bug; putting them back re-arms the crash-loop.
    raise ActiveRecord::IrreversibleMigration,
          "the btree indexes on post_versions tag arrays overflow on autotagger-sized deltas; do not restore them"
  end
end
