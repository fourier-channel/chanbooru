# frozen_string_literal: true

# A booru account in a creator's group (design CREATOR_VISIBILITY section 5).
# Written only through CreatorGroup#add_member! / #remove_member!.
#
# It says who added it (added_by) and how (source: the creator's hand, an
# approved join request, or automation), and may carry an expiry: an expired
# membership is NO membership, read as such by every reader (`active`), so a
# lapsed subscription ends access by itself and no job has to notice.
class CreatorGroupMembership < ApplicationRecord
  CREATOR = "creator"
  REQUEST = "request"
  AUTOMATION = "automation"
  SOURCES = [CREATOR, REQUEST, AUTOMATION].freeze

  belongs_to :creator_group
  belongs_to :user
  belongs_to :added_by, class_name: "User"

  validates :source, inclusion: { in: SOURCES }
  validates :user_id, uniqueness: { scope: :creator_group_id }
  # A date already gone would add someone who is out again at once: the
  # panel's "until" field and automation alike get the remedy instead
  # (creator panel, 2026-10-09; fail loudly, 2026-09-13).
  validate :expiry_ahead, if: :will_save_change_to_expires_at?

  # Memberships that count at `now`.
  scope :active, ->(now = Time.zone.now) { where(expires_at: nil).or(where(arel_table[:expires_at].gt(now))) }

  def manual? = source.in?([CREATOR, REQUEST])

  # The `active` scope, for one row in hand.
  def active?(now = Time.zone.now) = expires_at.nil? || expires_at > now

  private

  def expiry_ahead
    errors.add(:base, "That date has passed; choose a later one, or leave it empty for no end.") if expires_at.present? && expires_at <= Time.zone.now
  end
end
