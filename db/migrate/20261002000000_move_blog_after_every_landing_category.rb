# frozen_string_literal: true

# The Blog row moves from second to LAST.
#
# Second was meant to make it "secondary" (operator, 2026-09-30: "This should
# default to 'secondary' during testing") -- shown, but never the row the
# carousel opens on. That assumed Fresh from DEGEN leads. Production runs
# Featured Creators alone, at the END of the order (measured after the
# 2026-10-02 deploy: only featured enabled, at position 4), so ticking Blog at
# position 1 would have made it the opening row: the opposite of secondary.
# Last is secondary whatever else is on.
#
# Closes the gap the blog leaves, then puts it after the last row, so the
# others keep their order. No blog row, no change. Raw SQL and no model, as
# the earlier landing migrations explain.
class MoveBlogAfterEveryLandingCategory < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE landing_categories SET "position" = "position" - 1, updated_at = now()
       WHERE "position" > (SELECT "position" FROM landing_categories WHERE key = 'blog')
    SQL
    execute(<<~SQL.squish)
      UPDATE landing_categories
         SET "position" = (SELECT COALESCE(MAX("position"), -1) + 1 FROM landing_categories WHERE key <> 'blog'),
             updated_at = now()
       WHERE key = 'blog'
    SQL
  end

  # Back to second, as 20260930000000 left it.
  def down
    execute(<<~SQL.squish)
      UPDATE landing_categories SET "position" = "position" + 1, updated_at = now()
       WHERE "position" >= 1 AND key <> 'blog'
         AND EXISTS (SELECT 1 FROM landing_categories WHERE key = 'blog')
    SQL
    execute(%{UPDATE landing_categories SET "position" = 1, updated_at = now() WHERE key = 'blog'})
  end
end
