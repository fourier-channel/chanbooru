# frozen_string_literal: true

# A post the creator has chosen for one band of their gallery, with an
# ordering position: the hero band, or miniband 1 to 6 (CreatorGalleryLayout).
# One row per (gallery, band, post); a post may sit in several bands.
class CreatorGalleryPost < ApplicationRecord
  BANDS = %w[hero mini1 mini2 mini3 mini4 mini5 mini6].freeze

  belongs_to :creator_gallery
  belongs_to :post

  validates :band, inclusion: { in: BANDS }
  validates :post_id, uniqueness: { scope: [:creator_gallery_id, :band] }
end
