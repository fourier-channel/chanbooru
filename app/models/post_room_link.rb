# frozen_string_literal: true

# A Matrix room a posting bot sent a link to this post into (operator,
# 2026-11-24: "Yes, add room links"). fourier-sampling's lens posts a
# reference to a booru post (content "net.41chan.booru") into each board's
# room and reports the room first, on POST /posts/:post_id/tag_sources with
# "room" (FourierTagSourcesController#create_with_room).
#
# NOT A PLACEMENT. posts.room_ids, and so Gate 3, never reads these rows: the
# post stays exactly as visible as it was. A link only lets the post's
# withheld 404 -- and its `jailed`, which Technetium draws as
# "[This post has been deemed irrelevant.]" -- reach a member of a linked room
# (MediaDoorAsk.withheld?). They saw the link posted, so the answer tells them
# nothing of the post's existence they did not have.
#
#   source 'lens'      reported by the lens as it sent the link
#   source 'backfill'  written for a link sent before the lens reported them,
#                      from the lens journals; deletable by source alone
class PostRoomLink < ApplicationRecord
  LENS = "lens"
  BACKFILL = "backfill"
  SOURCES = [LENS, BACKFILL].freeze

  belongs_to :post
  belongs_to :matrix_room

  # Record that a link to `post` was sent into `room_id` (a Matrix room id
  # string). Re-sending is a no-op: the first source stands.
  def self.record!(post, room_id, source: LENS)
    raise ArgumentError, "source must be one of #{SOURCES.join(", ")}, got #{source.inspect}" unless SOURCES.include?(source)

    interned = MatrixRoom.intern!([room_id]).fetch(room_id)
    now = Time.zone.now
    insert_all([{ post_id: post.id, matrix_room_id: interned, source: source, created_at: now, updated_at: now }], unique_by: [:post_id, :matrix_room_id])
    interned
  end

  # Whether a link to `post` was sent into a room `user` is joined to
  # (MatrixViewerRooms.ids: the request's own verified viewer only).
  def self.linked_for?(post, user)
    rooms = MatrixViewerRooms.ids(user).select(&:positive?)
    rooms.any? && where(post_id: post.id, matrix_room_id: rooms).exists?
  end
end
