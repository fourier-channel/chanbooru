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

  # WHICH CREATOR TAGS A MATRIX ID MAY CLAIM (operator ruling 2026-10-04).
  # Every post carries a creator tag whose prefix is its provenance:
  # 4chan_<name> scraped from 4chan, 41chan_<name> posted from Matrix,
  # aichan_<name> posted from the AIchan Discord. 41chan_<localpart> is the
  # MASTER creator, linked to the Matrix identity; the other two are claimable
  # by that identity "only if they are identical once the prefix is stripped."
  # A tag without one of these prefixes is not covered by the rule.
  CREATOR_PREFIX = /\A(4chan|41chan|aichan)_(.+)\z/

  validates :status, inclusion: { in: STATUSES }
  validate :one_approved_claim_per_artist, if: :approved?
  validate :creator_tag_matches_claimant

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

  # The stripped-prefix rule. Compared against the gallery's matrix_id, which
  # fourier-auth verified when the gallery was made -- never against anything
  # the request says.
  def creator_tag_matches_claimant
    m = CREATOR_PREFIX.match(artist&.name.to_s)
    return unless m

    localpart = creator_gallery&.matrix_id.to_s[/\A@([^:]+):/, 1]
    return if localpart.present? && localpart == m[2]

    errors.add(:artist, "#{artist.name} can only be claimed by the Matrix account @#{m[2]}: a #{m[1]}_ creator tag " \
                        "is claimable only when it is identical to the claimant's 41chan_ name once the prefix is stripped")
  end

  # Belt to the database index's braces. The index refuses the write; this
  # produces a readable error instead of a constraint violation.
  def one_approved_claim_per_artist
    clash = ArtistClaim.approved.where(artist_id: artist_id).where.not(id: id).exists?
    errors.add(:artist, "already has an approved claim") if clash
  end
end
