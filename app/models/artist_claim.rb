# frozen_string_literal: true

# A creator's claim on an artist tag: who says it is theirs, and whether a
# moderator has agreed yet.
#
# This is the join that makes tier 5 mean anything. "Confirmed Creator" is not a
# level someone is set to -- it is a level PLUS an approved claim, and the claim
# is what turns a general permission into a permission over one artist's work.
class ArtistClaim < ApplicationRecord
  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  STATUSES = [PENDING, APPROVED, REJECTED].freeze

  belongs_to :artist
  belongs_to :creator_gallery
  belongs_to :approver, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validate :one_approved_claim_per_artist, if: :approved?

  scope :approved, -> { where(status: APPROVED) }
  scope :pending, -> { where(status: PENDING) }

  def pending? = status == PENDING
  def approved? = status == APPROVED
  def rejected? = status == REJECTED

  # The booru account behind the claim.
  #
  # Read through the gallery rather than stored again here, so there is one
  # answer to "whose is this" and it cannot come apart. The gallery's matrix_id
  # was verified by fourier-auth when the gallery was made; user_id is the
  # account that was signed in at that moment.
  def claimant = creator_gallery&.user

  # Whether this user owns this artist, right now.
  #
  # Deliberately a READ of two stored rows rather than anything derived from the
  # request. The verified Matrix identity arrives in a header, which no Pundit
  # policy can see and which is absent from API calls and background jobs
  # entirely -- so identity is established once, at claim time, under a verified
  # session, and every later question is answered from the database.
  def self.owner?(user, artist)
    return false if user.nil? || artist.nil? || user.is_anonymous?

    # An edit TagGrant on the artist's tag confers exactly what an approved
    # claim does -- the admin console's way of assigning "that exact set of
    # permissions over that exact tag" (operator, 2026-09-04) without walking
    # the claim flow.
    return true if TagGrant.granted?(user, [artist.name], "edit")

    approved.joins(:creator_gallery)
            .exists?(artist_id: artist.id, creator_galleries: { user_id: user.id })
  end

  def approve!(by:)
    update!(status: APPROVED, approver: by, decided_at: Time.zone.now)
  end

  def reject!(by:, note: "")
    update!(status: REJECTED, approver: by, decided_at: Time.zone.now, note: note)
  end

  private

  # Belt to the database index's braces. The index refuses the write; this
  # produces a readable error instead of a constraint violation.
  def one_approved_claim_per_artist
    clash = ArtistClaim.approved.where(artist_id: artist_id).where.not(id: id).exists?
    errors.add(:artist, "already has an approved claim") if clash
  end
end
