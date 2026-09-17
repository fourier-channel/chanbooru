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
  # `id: :desc` is a TIE-BREAK, not decoration. Two galleries promoted in the
  # same request share a promoted_at to the microsecond, and an unstable sort
  # then reorders the front page between one render and the next for no reason
  # a reader could name.
  scope :promoted, -> { where.not(promoted_at: nil).order(promoted_at: :desc, id: :desc) }

  # HOW MANY THE LANDING PAGE TAKES, stated once.
  #
  # It used to be stated twice and the two disagreed. LandingShowcase took
  # `promoted.limit(6)` flat; LandingController took `promoted`, removed the
  # current feature, THEN limited to 6. So the carousel row and the card row
  # beneath it could draw from different sets of galleries -- off by one
  # whenever a gallery was both featured and promoted, which is a state the
  # admin console will make ordinary.
  #
  # The exclusion is gone rather than copied to the other caller. Its stated
  # reason was that the feature "is shown in its own section, so it does not
  # also appear in the row underneath it", and that section no longer exists --
  # the operator superseded it on 2026-09-17. Nothing writes featured_at
  # either, so the exclusion has never once removed a gallery in production.
  LANDING_LIMIT = 6

  def self.landing_promoted(limit = LANDING_LIMIT)
    promoted.limit(limit)
  end

  # The current feature is simply the most recently featured one. No cron job,
  # no month arithmetic, nothing to expire: setting a new feature is the whole
  # act, and until someone does, last month's stands rather than the page
  # showing an empty slot.
  # PARKED, 2026-09-17, and deliberately not deleted.
  #
  # featured_at backed "Creator of the month", a single gallery in its own
  # section on the landing page. That section is gone: the idea became the
  # plural "Featured Creators" carousel row, which is configured by ARTIST TAGS
  # on the landing console and does not read this column.
  #
  # It is kept for the expansion the operator named -- pinning a GALLERY to
  # that row rather than a tag -- which is what this column already models.
  # NOTHING READS IT TODAY and nothing ever wrote it; if that expansion is
  # dropped, drop the column with it rather than leaving a plausible name
  # attached to nothing, which is exactly what made it cost an afternoon to
  # work out the difference between this and promoted_at.
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
