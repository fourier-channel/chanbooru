# frozen_string_literal: true

class CreateCreatorGalleries < ActiveRecord::Migration[8.1]
  def change
    create_table :creator_galleries do |t|
      t.string  :slug,           null: false           # URL key (Matrix localpart)
      t.string  :matrix_id,      null: false           # full MXID, @slug:domain
      t.bigint  :user_id                               # optional linked Danbooru user
      t.string  :title,          null: false, default: ""
      t.text    :bio,            null: false, default: ""
      t.string  :style,          null: false, default: "grid"
      t.string  :matrix_contact, null: false, default: "" # MXID to message (defaults to matrix_id)
      t.jsonb   :settings,       null: false, default: {}
      t.timestamps
    end
    add_index :creator_galleries, :slug, unique: true
    add_index :creator_galleries, :matrix_id, unique: true
    add_index :creator_galleries, :user_id

    create_table :creator_gallery_posts do |t|
      t.references :creator_gallery, null: false, foreign_key: true, index: true
      t.bigint  :post_id, null: false
      t.integer :position, null: false, default: 0
      t.datetime :created_at, null: false
    end
    add_index :creator_gallery_posts, [:creator_gallery_id, :post_id], unique: true
    add_index :creator_gallery_posts, :post_id

    create_table :creator_gallery_messages do |t|
      t.references :creator_gallery, null: false, foreign_key: true, index: true
      t.text :body, null: false, default: ""
      t.timestamps
    end
  end
end
