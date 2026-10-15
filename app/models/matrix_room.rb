# frozen_string_literal: true

# A Matrix room id interned to a small integer (GATE 3 FOR POSTS, fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md), so a post's rooms and a viewer's rooms
# are int[] and the gate is one overlap. Ids start at 1: 0 and -1 are reserved
# (MatrixViewerRooms::NOT_MATRIX, ::SITE_ASSET). Rows are only ever added --
# by the placements feed (MatrixPlacements) -- never renumbered or removed.
class MatrixRoom < ApplicationRecord
  # A Matrix room id: "!" opaque "@"-free localpart ":" server name.
  ROOM_ID = /\A![^:\s]{1,255}:[^\s]{1,255}\z/

  # { room_id string => interned id } for `room_ids`, adding the ones not yet
  # seen. One INSERT .. ON CONFLICT and one SELECT, whatever the count.
  def self.intern!(room_ids)
    room_ids = room_ids.uniq
    return {} if room_ids.empty?

    now = Time.zone.now
    insert_all(room_ids.map { |room_id| { room_id: room_id, created_at: now, updated_at: now } }, unique_by: :room_id)
    where(room_id: room_ids).pluck(:room_id, :id).to_h
  end
end
