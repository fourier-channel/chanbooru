# frozen_string_literal: true

# One row per carousel category, so the front page can be re-aimed without a
# deploy. LandingSetting described ONE row (the "new" one) and the other two
# were hardcoded in LandingShowcase; there are four now and all of them are
# configurable, so the shape had to become a table.
#
# The seed is RAW SQL and references no model on purpose. db:prepare runs in
# the same container command as the server, so a migration that raises does not
# degrade the carousel -- the app never boots. A migration that reaches for a
# model also breaks the next time that model changes, which is a fault that
# arrives long after the commit that caused it.
class CreateLandingCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :landing_categories do |t|
      # An IDENTIFIER, never editable from the panel: it reaches the browser as
      # data-cat and as the payload's category key, and an identifier an admin
      # can retype is one that breaks.
      t.string  :key,        null: false
      t.string  :label,      null: false
      t.boolean :enabled,    null: false, default: true
      t.integer :position,   null: false, default: 0
      t.string  :kind,       null: false
      t.string  :board
      t.boolean :fresh_only, null: false, default: true
      t.text    :tags,       array: true, null: false, default: []
      t.string  :ordering,   null: false, default: "new"
      # RESERVED for pinning a gallery to a row instead of a tag; read by
      # nothing today. nullify because deleting a creator's gallery must never
      # be blocked by a front-page config row.
      t.references :creator_gallery, null: true, foreign_key: { on_delete: :nullify }
      t.integer :updated_by_id
      t.timestamps
    end

    # Four rows. No other index: the planner seq-scans four rows whatever you
    # build for it.
    add_index :landing_categories, :key, unique: true

    reversible do |dir|
      dir.up do
        # COALESCE is the whole answer to "does the front page change today".
        # Whatever the admin last saved at /admin/landing_setting is what the
        # 'new' row carries over. Positions preserve the current on-screen
        # order. 'featured' is seeded DISABLED with no tags, so it appears the
        # day an admin fills it in and never as an empty row.
        execute(<<~SQL.squish)
          INSERT INTO landing_categories
            (key, label, enabled, "position", kind, board, fresh_only, tags, ordering, created_at, updated_at)
          VALUES
            ('new',
             COALESCE((SELECT label FROM landing_settings ORDER BY id LIMIT 1), 'Fresh from DEGEN'),
             true, 0, 'board',
             COALESCE((SELECT board FROM landing_settings ORDER BY id LIMIT 1), 'b'),
             COALESCE((SELECT fresh_only FROM landing_settings ORDER BY id LIMIT 1), true),
             '{}', 'new', now(), now()),
            ('favorites', 'Community Favorites', true,  1, 'tags',      NULL, true, '{}', 'favcount', now(), now()),
            ('promoted',  'Promoted Creators',  true,  2, 'galleries',  NULL, true, '{}', 'new',      now(), now()),
            ('featured',  'Featured Creators',  false, 3, 'tags',       NULL, true, '{}', 'new',      now(), now())
          ON CONFLICT (key) DO NOTHING
        SQL
      end
    end
  end
end
