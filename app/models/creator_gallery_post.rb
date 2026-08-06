# frozen_string_literal: true

# A post the creator has chosen to feature on their gallery, with an ordering
# position. One row per (gallery, post).
class CreatorGalleryPost < ApplicationRecord
  belongs_to :creator_gallery
  belongs_to :post

  validates :post_id, uniqueness: { scope: :creator_gallery_id }
end
