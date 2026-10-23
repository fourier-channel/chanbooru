# frozen_string_literal: true

# The creator gallery's bands (Creator Gallery rebuild, 2026-10-23). A
# gallery's top is its HERO BAND, and under it sit up to six MINIBANDS, each
# a row of chosen posts: a chosen post now says which band it is in, and a
# post may sit in several. Existing rows were the one curated set, which is
# the hero band now. The layout style is gone with them -- minibands replace
# styles, and a replaced rule is deleted, not kept (WORKING-RULES 7).
class CreatorGalleryBands < ActiveRecord::Migration[8.1]
  def change
    add_column :creator_gallery_posts, :band, :string, null: false, default: "hero"
    remove_index :creator_gallery_posts, [:creator_gallery_id, :post_id], unique: true
    add_index :creator_gallery_posts, [:creator_gallery_id, :band, :post_id], unique: true, name: "index_creator_gallery_posts_on_gallery_band_post"
    remove_column :creator_galleries, :style, :string, null: false, default: "grid"
  end
end
