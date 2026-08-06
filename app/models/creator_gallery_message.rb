# frozen_string_literal: true

# A blog-style message on a creator's gallery page.
class CreatorGalleryMessage < ApplicationRecord
  belongs_to :creator_gallery

  validates :body, presence: true, length: { maximum: 5000 }
end
