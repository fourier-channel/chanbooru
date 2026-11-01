# frozen_string_literal: true

# A post's APPLIED VIEW on one creator's page (operator, 2026-11-01): "moving
# post 12345 up 50 pixels and shrinking it by 10% gets saved as its 'applied
# view' and is automatically re-applied as is the next time that image is
# chosen, with the creator being able to click 'reset' at any time."
#
# One row per gallery and post; no row is the identity. Integers only:
#   flip_h, flip_v  mirrored across the vertical / horizontal axis
#   x, y            pan, in permille of the frame's width / height, -1000..1000
#   scale           milli, on top of the cover fit, 200..4000
#   stretch         milli, the width multiplier against the height (Distort), 500..2000
# The ranges are the model's validations, as the harmonics table's are.
#
# post_id has no foreign key, like a harmonic's background_post_id: a view of
# a deleted post is simply never drawn. The gallery's rows cascade with it.
class CreateCreatorGalleryPostViews < ActiveRecord::Migration[8.1]
  def change
    create_table :creator_gallery_post_views do |t|
      t.references :creator_gallery, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.bigint :post_id, null: false
      t.boolean :flip_h, null: false, default: false
      t.boolean :flip_v, null: false, default: false
      t.integer :x, limit: 2, null: false, default: 0
      t.integer :y, limit: 2, null: false, default: 0
      t.integer :scale, limit: 2, null: false, default: 1000
      t.integer :stretch, limit: 2, null: false, default: 1000
      t.timestamps
    end
    add_index :creator_gallery_post_views, [:creator_gallery_id, :post_id], unique: true, name: "index_creator_gallery_post_views_on_gallery_and_post"
  end
end
