# frozen_string_literal: true

# ROOM LINKS (operator, 2026-11-24: "Yes, add room links"): the Matrix rooms a
# posting bot sent a LINK to a booru post into -- fourier-sampling's lens posts
# a reference to the post (content "net.41chan.booru") into the board's room.
#
# A link is not a placement. posts.room_ids stays what PostMxc derives it from
# (Gate 3): writing a lens room there would make the post a Matrix post and
# hide a public post from everyone outside the room. A link only lets the
# post's withheld/jailed 404 (FourierTagSourcesController#show,
# MediaDoorAsk.withheld?) reach a member of the room, who saw the link posted.
#
# Additive: one new table, nothing existing changes.
class CreatePostRoomLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :post_room_links do |t|
      t.integer :post_id, null: false
      t.integer :matrix_room_id, null: false
      t.string :source, null: false
      t.timestamps
      t.index [:post_id, :matrix_room_id], unique: true
      t.check_constraint "source IN ('lens', 'backfill')", name: "post_room_links_source"
    end
    add_foreign_key :post_room_links, :posts, on_delete: :cascade
    add_foreign_key :post_room_links, :matrix_rooms
  end
end
