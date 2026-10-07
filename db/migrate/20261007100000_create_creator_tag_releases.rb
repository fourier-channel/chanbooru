# frozen_string_literal: true

# A creator RELEASED from their prefix's default visibility (operator,
# 2026-10-07): "public in this case just means that they can then scope
# visibility according to the individual creator tag and not the entire
# guildtag." One row per creator tag, never deleted: returning a creator to
# the default sets released false, so the row's updater and note always say
# who decided last and why.
class CreateCreatorTagReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :creator_tag_releases do |t|
      t.string :tag_name, null: false
      t.boolean :released, null: false, default: false
      t.references :updater, null: false, foreign_key: { to_table: :users }
      t.string :note, null: false, default: ""
      t.timestamps
    end
    add_index :creator_tag_releases, :tag_name, unique: true
  end
end
