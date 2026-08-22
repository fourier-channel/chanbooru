# frozen_string_literal: true

# A creator's individualized presentation page: a curated selection of their
# posts, blog-style messages, and a Matrix contact link. Keyed by a Matrix
# identity (MXID); write access is gated to that identity or an admin (see
# CreatorGalleriesController + FourierIdentity).
class CreatorGallery < ApplicationRecord
  STYLES = %w[grid masonry filmstrip spotlight].freeze

  belongs_to :user, optional: true
  has_many :creator_gallery_posts, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :creator_gallery
  has_many :posts, through: :creator_gallery_posts
  has_many :creator_gallery_messages, -> { order(created_at: :desc) }, dependent: :destroy, inverse_of: :creator_gallery

  validates :slug, presence: true, uniqueness: true, format: { with: %r{\A[a-z0-9._=\-/]+\z} }
  validates :matrix_id, presence: true, uniqueness: true
  validates :style, inclusion: { in: STYLES }
  validates :title, length: { maximum: 120 }
  validates :bio, length: { maximum: 4000 }

  # Landing-page promotion. Timestamps, not flags: promoted wants an order, and
  # "creator of the month" wants history -- setting this month's feature must
  # not erase who it was last month.
  scope :promoted, -> { where.not(promoted_at: nil).order(promoted_at: :desc) }

  # The current feature is simply the most recently featured one. No cron job,
  # no month arithmetic, nothing to expire: setting a new feature is the whole
  # act, and until someone does, last month's stands rather than the page
  # showing an empty slot.
  def self.current_feature
    where.not(featured_at: nil).order(featured_at: :desc).first
  end

  before_validation :default_contact

  # URL key is the slug (Matrix localpart), not the numeric id.
  def to_param = slug

  # The MXID a visitor should message; falls back to the owning identity.
  def contact = matrix_contact.presence || matrix_id

  private

  def default_contact
    self.matrix_contact = matrix_id if matrix_contact.blank?
  end
end
