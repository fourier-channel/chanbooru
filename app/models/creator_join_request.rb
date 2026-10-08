# frozen_string_literal: true

# A request to join a creator's group (design CREATOR_VISIBILITY Q5, ruled
# 2026-10-07: "a user requests to join, the creator approves or refuses").
#
# Approving adds the member through CreatorGroup#add_member! -- the creator's
# own manual add, with source "request" -- so there is one way into a group
# however the decision was reached. Refusing keeps the row (who asked, who
# refused, why), and the user may ask again afterwards; one open request per
# user and group at a time (a partial unique index backs that).
class CreatorJoinRequest < ApplicationRecord
  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  STATUSES = [PENDING, APPROVED, REJECTED].freeze

  belongs_to :creator_group
  belongs_to :user
  belongs_to :decided_by, class_name: "User", optional: true

  normalizes :note, with: ->(note) { note.to_s.strip.truncate(500) }

  validates :status, inclusion: { in: STATUSES }
  validate :one_open_request, on: :create
  validate :not_already_a_member, on: :create
  validate :not_banned, on: :create

  scope :pending, -> { where(status: PENDING) }

  def pending? = status == PENDING

  # A request filed before the user joined some other way (automation, say,
  # with an expiry) is approved WITHOUT touching that membership: re-adding
  # would replace its expiry with none, and a lapsed subscription would never
  # end access (section 5). The log says which happened.
  def approve!(by:)
    transaction do
      decide!(by: by, status: APPROVED)
      current = CreatorGroupMembership.active.find_by(creator_group_id: creator_group_id, user_id: user_id)
      creator_group.add_member!(user, by: by, source: CreatorGroupMembership::REQUEST) unless current
      kept = " (already a member#{", until #{current.expires_at.utc.iso8601}" if current&.expires_at}; membership unchanged)" if current
      ModAction.log("approved user ##{user_id}'s request to join creator group #{creator_group.name}#{kept}",
                    :creator_join_request_approve, subject: creator_group.creator_gallery, user: by)
    end
  end

  def reject!(by:, note: "")
    transaction do
      decide!(by: by, status: REJECTED, note: note)
      ModAction.log("refused user ##{user_id}'s request to join creator group #{creator_group.name}#{": #{self.note}" if self.note.present?}",
                    :creator_join_request_reject, subject: creator_group.creator_gallery, user: by)
    end
  end

  private

  def decide!(by:, status:, **attrs)
    raise User::PrivilegeError, "Only this creator or an admin can decide a request to join their group." unless creator_group.creator_gallery.managed_by?(by)

    unless pending?
      errors.add(:base, "This request was already #{self.status}; the user can ask again")
      raise ActiveRecord::RecordInvalid, self
    end

    update!(status: status, decided_by: by, decided_at: Time.zone.now, **attrs)
  end

  def one_open_request
    errors.add(:base, "A request to join #{creator_group&.name} is already waiting for its creator") if CreatorJoinRequest.pending.exists?(creator_group_id: creator_group_id, user_id: user_id)
  end

  def not_already_a_member
    errors.add(:base, "Already a member of #{creator_group&.name}") if CreatorGroupMembership.active.exists?(creator_group_id: creator_group_id, user_id: user_id)
  end

  def not_banned
    errors.add(:base, "A banned account cannot ask to join a creator's group") if user&.is_banned?
  end
end
