# frozen_string_literal: true

# A post's APPLIED VIEW on one creator's page (operator, 2026-11-01): how the
# creator moved, scaled, stretched or flipped that picture, saved per gallery,
# place and post so it re-applies the next time the post is chosen there,
# until they Reset it. No row is the identity, so saving the identity deletes
# the row.
#
# place:          the frame it is fitted to (operator, 2026-11-07): the
#                 banner, the hero band's thumbnails, a miniband or a
#                 channel's picture. Each is a frame of its own shape.
# flip_h, flip_v: mirrored across the vertical / horizontal axis.
# x, y:           pan, in permille of the frame's width / height.
# scale:          milli, on top of the cover fit.
# stretch:        milli, the width multiplier against the height (Distort).
#
# Written only through the gallery's Save, under the gallery's lock.
class CreatorGalleryPostView < ApplicationRecord
  LIMITS = { x: -1000..1000, y: -1000..1000, scale: 200..4000, stretch: 500..2000 }.freeze
  IDENTITY = { flip_h: false, flip_v: false, x: 0, y: 0, scale: 1000, stretch: 1000 }.freeze
  PLACES = %w[banner hero mini channel].freeze

  belongs_to :creator_gallery

  validates :post_id, presence: true, uniqueness: { scope: [:creator_gallery_id, :place] }
  validates :place, inclusion: { in: PLACES, message: "must be one of #{PLACES.join(", ")}" }
  validates :flip_h, :flip_v, inclusion: { in: [true, false], message: "must be on or off" }
  LIMITS.each do |field, range|
    validates field, numericality: { only_integer: true, in: range, message: "must be a whole number between #{range.min} and #{range.max}" }
  end

  # The view as CreatorGalleryLayout#draw hands it to the page and the editor.
  def value = IDENTITY.keys.index_with { |field| self[field] }

  # The view as a CSS transform about the picture's centre, "" for the
  # identity (or no view): the pan in percent of the frame, then one scale
  # carrying the stretch across and the flips. post_view.js#transform draws
  # the same string (test/fixtures/files/post_views.json).
  #
  # @param view [Hash, nil] symbol keys; an absent field is the identity's
  def self.transform(view)
    view = IDENTITY.merge(view.to_h.slice(*IDENTITY.keys))
    return "" if view == IDENTITY

    across = view[:scale] * view[:stretch] / 1_000_000.0 * (view[:flip_h] ? -1 : 1)
    down = view[:scale] / 1000.0 * (view[:flip_v] ? -1 : 1)
    "translate(#{css(view[:x] / 10.0)}%, #{css(view[:y] / 10.0)}%) scale(#{css(across)}, #{css(down)})"
  end

  # The view as the --cg-view variable a banner, ground or miniband image
  # composes into its own transform; "" for the identity.
  def self.style(view)
    transform = transform(view)
    transform.empty? ? "" : "--cg-view: #{transform}"
  end

  # A harmonic's picture style: the view applied about the card's centre,
  # then the card's own zoom about its focus, which stays the origin.
  #
  # @param picture [Hash] focus_x, focus_y, zoom and the post's view (or nil)
  def self.picture_style(picture)
    fx, fy = picture.values_at(:focus_x, :focus_y)
    view = transform(picture[:view])
    around = view.empty? ? "" : "translate(#{50 - fx}%, #{50 - fy}%) #{view} translate(#{fx - 50}%, #{fy - 50}%) "
    "object-position: #{fx}% #{fy}%; transform-origin: #{fx}% #{fy}%; transform: #{around}scale(#{css(picture[:zoom] / 100.0)})"
  end

  # A number as both readers print it: Ruby's and JavaScript's shortest
  # round-trip form, a whole number without its ".0".
  private_class_method def self.css(number) = number.to_s.delete_suffix(".0")
end
