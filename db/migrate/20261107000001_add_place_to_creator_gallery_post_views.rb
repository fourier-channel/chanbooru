# frozen_string_literal: true

# A post's applied view is per PLACE (operator, 2026-11-07): "every post
# assigned to the band has its thumbnail custom set" -- the banner, the hero
# band's thumbnails, the minibands and the channels' pictures are frames of
# different shapes, and a framing fitted to one is wrong in the next. So a
# view is kept per gallery, place and post.
#
# Until now one view drew on the banner, a miniband and a channel alike, and
# never on the hero band. Each row is copied to those three places, so every
# page draws exactly what it drew before; the hero band starts with none.
class AddPlaceToCreatorGalleryPostViews < ActiveRecord::Migration[8.1]
  def up
    add_column :creator_gallery_post_views, :place, :string
    remove_index :creator_gallery_post_views, name: "index_creator_gallery_post_views_on_gallery_and_post"
    execute <<~SQL.squish
      INSERT INTO creator_gallery_post_views (creator_gallery_id, post_id, place, flip_h, flip_v, x, y, scale, stretch, created_at, updated_at)
      SELECT creator_gallery_id, post_id, places.place, flip_h, flip_v, x, y, scale, stretch, created_at, updated_at
      FROM creator_gallery_post_views CROSS JOIN (VALUES ('mini'), ('channel')) AS places(place)
      WHERE creator_gallery_post_views.place IS NULL
    SQL
    execute "UPDATE creator_gallery_post_views SET place = 'banner' WHERE place IS NULL"
    change_column_null :creator_gallery_post_views, :place, false
    add_index :creator_gallery_post_views, [:creator_gallery_id, :place, :post_id], unique: true, name: "index_creator_gallery_post_views_on_gallery_place_and_post"
  end

  # Back to one view per post: the banner's, else the miniband's, else the
  # channel's; the hero band's go.
  def down
    execute <<~SQL.squish
      DELETE FROM creator_gallery_post_views WHERE id NOT IN (
        SELECT DISTINCT ON (creator_gallery_id, post_id) id FROM creator_gallery_post_views WHERE place <> 'hero'
        ORDER BY creator_gallery_id, post_id, array_position(ARRAY['banner', 'mini', 'channel']::varchar[], place)
      )
    SQL
    remove_index :creator_gallery_post_views, name: "index_creator_gallery_post_views_on_gallery_place_and_post"
    remove_column :creator_gallery_post_views, :place
    add_index :creator_gallery_post_views, [:creator_gallery_id, :post_id], unique: true, name: "index_creator_gallery_post_views_on_gallery_and_post"
  end
end
