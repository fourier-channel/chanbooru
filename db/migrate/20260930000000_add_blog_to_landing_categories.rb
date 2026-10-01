# frozen_string_literal: true

# The carousel's Blog row, seeded SECOND, so that once it is on it is not the
# row the carousel opens on (operator, 2026-09-30: "This should default to
# 'secondary' during testing") -- and seeded OFF, so a deploy shows nothing
# new until it is turned on in the landing console (operator, 2026-10-01).
# The carousel opens on the first row by position, so the blog takes
# position 1 and every row at 1 or later moves down one, keeping its order. LandingCategory::DEFAULTS carries the same order for a database that
# never runs this (db:prepare loads structure.sql and marks it run).
#
# Raw SQL and no model, for the reason the first landing migration gives.
# Both statements are guarded so a re-run, or a blog row made by hand, cannot
# shift the others twice, and the insert only runs on a table that already
# holds rows: an EMPTY table takes every row, the blog included, from
# DEFAULTS, and the first save in the landing console writes them all.
class AddBlogToLandingCategories < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE landing_categories SET "position" = "position" + 1, updated_at = now()
       WHERE "position" >= 1
         AND NOT EXISTS (SELECT 1 FROM landing_categories WHERE key = 'blog')
    SQL
    execute(<<~SQL.squish)
      INSERT INTO landing_categories
        (key, label, enabled, "position", kind, board, fresh_only, tags, ordering, created_at, updated_at)
      SELECT 'blog', 'Blog', false, 1, 'blog', NULL, true, '{}'::text[], 'new', now(), now()
       WHERE EXISTS (SELECT 1 FROM landing_categories)
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE landing_categories SET "position" = "position" - 1, updated_at = now()
       WHERE "position" > (SELECT "position" FROM landing_categories WHERE key = 'blog')
    SQL
    execute("DELETE FROM landing_categories WHERE key = 'blog'")
  end
end
