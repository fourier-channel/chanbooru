# frozen_string_literal: true

# GATE 3 FOR POSTS, the record (fourier-basis docs/design/GATE3_MATRIX_POSTS.md,
# piece D). Additive: four new tables, nothing existing changes.
#
#   matrix_rooms    -- Matrix room ids interned to small integers, so a post's
#                      and a viewer's room sets are int[] (0 and -1 are
#                      reserved: "not a Matrix post" and "a site asset").
#   matrix_media    -- fourier-auth's answer for each mxc, pushed to
#                      POST /fourier_jail/release.json (placements): who
#                      uploaded it, whether it is a site asset, the rooms it
#                      counts in, and the Synapse snapshot the answer was read
#                      at. Kept for mxcs not yet posted.
#   post_mxcs       -- every address of a post's image: its own source
#                      ('post_source') and the tunnel's re-uploads of the
#                      same bytes ('alias'). An mxc belongs to one post.
#   matrix_placement_cursors -- where each of fourier-auth's two readers
#                      (live, sweep) has pushed up to; it only moves up.
class CreateGate3MatrixRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :matrix_rooms, id: :integer do |t|
      t.string :room_id, null: false
      t.timestamps
      t.index :room_id, unique: true
    end

    create_table :matrix_media do |t|
      t.string :mxc, null: false
      t.string :uploader, null: false, default: ""
      t.boolean :site_asset, null: false, default: false
      t.integer :room_ids, array: true, null: false, default: []
      t.bigint :snapshot_head, null: false
      t.datetime :snapshot_at, null: false
      t.bigint :newest_ordering
      t.timestamps
      t.index :mxc, unique: true
    end

    create_table :post_mxcs do |t|
      t.integer :post_id, null: false
      t.string :mxc, null: false
      t.string :source, null: false
      t.timestamps
      t.index :mxc, unique: true
      t.index :post_id
      t.check_constraint "source IN ('post_source', 'alias')", name: "post_mxcs_source"
    end
    add_foreign_key :post_mxcs, :posts, on_delete: :cascade

    create_table :matrix_placement_cursors do |t|
      t.string :stream, null: false
      t.bigint :position, null: false, default: 0
      t.datetime :lap_started_at
      t.timestamps
      t.index :stream, unique: true
      t.check_constraint "stream IN ('live', 'sweep')", name: "matrix_placement_cursors_stream"
    end
  end
end
