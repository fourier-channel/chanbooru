# frozen_string_literal: true

# A PERK: a per-user, server-side grant that raises one of the account's
# limits (CREATOR_TUNER.md sec 4.4, operator 2026-10-31), given by an admin or
# a paid path. It is honoured only while the account is in good standing
# (User#perk_value): a restricted, banned or deleted account gets the
# default, and its grants back when that lifts.
#
# NEVER A LEVEL. Gold is a content gate in this fork, so a perk that bumped a
# level would open gated posts.
#
# One live grant per account and perk (a unique index where revoked_at is
# null). A new grant revokes the one before it; a revoke is an update, so the
# history stays. Every admin grant and revoke is logged where only admins
# read it.
class UserPerk < ApplicationRecord
  PERKS = {
    "creator_harmonic_cap" => { default: 5, max: 25, label: "Creator Tuner harmonics" },
  }.freeze
  SOURCES = %w[admin paid].freeze

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :perk, inclusion: { in: PERKS.keys }
  validates :source, inclusion: { in: SOURCES }
  validate :value_raises_the_default

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.zone.now) }

  def self.default(perk)
    PERKS.fetch(perk.to_s)[:default]
  end

  # @return [UserPerk] the new grant
  def self.grant!(user, perk, value:, by:, expires_at: nil)
    authorize!(by)

    transaction do
      where(user: user, perk: perk.to_s, revoked_at: nil).find_each { |row| row.update!(revoked_at: Time.zone.now, revoked_by: by) }
      row = create!(user: user, perk: perk.to_s, value: value, source: "admin", granted_by: by, expires_at: expires_at)
      until_words = expires_at ? " until #{expires_at.utc.iso8601}" : ""
      ModAction.log("granted #{PERKS[row.perk][:label]} #{value}#{until_words} to \"#{user.name}\":#{Routes.user_path(user)}",
                    :user_perk_grant, subject: user, user: by)
      row
    end
  end

  # @return [UserPerk, nil] the revoked grant; nil when there was none
  def self.revoke!(user, perk, by:)
    authorize!(by)

    transaction do
      row = find_by(user: user, perk: perk.to_s, revoked_at: nil)
      next nil if row.nil?

      row.update!(revoked_at: Time.zone.now, revoked_by: by)
      ModAction.log("revoked #{PERKS[row.perk][:label]} #{row.value} from \"#{user.name}\":#{Routes.user_path(user)}",
                    :user_perk_revoke, subject: user, user: by)
      row
    end
  end

  def self.authorize!(by)
    raise User::PrivilegeError, "Only an admin can grant or revoke a perk." unless by.is_admin?
  end

  private

  def value_raises_the_default
    entry = PERKS[perk]
    return if entry.nil? || value.to_i.in?((entry[:default] + 1)..entry[:max])

    errors.add(:value, "must be a whole number from #{entry[:default] + 1} to #{entry[:max]}: #{entry[:default]} is everyone's already")
  end
end
