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

  # Memberships that count at `now`.
  scope :active, ->(now = Time.zone.now) { where(expires_at: nil).or(where(arel_table[:expires_at].gt(now))) }
end
