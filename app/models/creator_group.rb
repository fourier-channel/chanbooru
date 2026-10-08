# frozen_string_literal: true

# A creator's group: a defined class of viewer the creator manages (design
# CREATOR_VISIBILITY section 5; operator, 2026-10-07: "a group is going to be
# a defined class of user -- for example, 41chan_saber_tier_1, and all tier 1
# users in that group can be managed by the artist and/or an automated system
# that lets users 'sign up'").
#
# NAMED FOR ITS CREATOR. The house rule, derived from that example: a group's
# name is its creator's MASTER creator tag (the prefix whose provenance is
# Matrix, today 41chan_, plus their Matrix localpart -- the tag CreatorControl
# gives them with no claim) followed by `_<suffix>`, lowercase words joined by
# single underscores. A suffix of exactly `tier_<n>` makes a TIERED group and
# its tier must be n; any other suffix is an untiered group. So the name says
# whose group it is and how it nests, and two creators cannot share one.
#
# TIERS NEST (Q3, ruled 2026-10-07): "tier_2 sees everything tier_1 sees" --
# within one creator. An untiered group is independent of every other group.
# Read by CreatorVisibility; stored here only as `tier`.
#
# ONE WRITE PATH FOR MEMBERS. add_member! and remove_member! are what the
# creator's panel calls, what an approved join request calls
# (CreatorJoinRequest#approve!), and what automation will call -- the
# dual-callable shape of ArtistClaim#approve!, never a second path. Each
# membership says who added it and how (source), and may expire: a lapsed
# subscription ends access by itself, with nothing to run.
#
# Every write is an admin-only ModAction (Q2: moderators see nothing a
# creator hid, nor who the creator let in), logged against the creator's
# page and naming the group in words: /mod_actions links every row's subject,
# a group has no page of its own, and a dissolved group's rows would point at
# nothing.
class CreatorGroup < ApplicationRecord
  belongs_to :creator_gallery
  # The database cascades these with the group.
  has_many :memberships, class_name: "CreatorGroupMembership", dependent: nil
  has_many :join_requests, class_name: "CreatorJoinRequest", dependent: nil

  WORDS = /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/

  normalizes :name, with: ->(name) { name.to_s.strip.downcase }

  validates :name, presence: true, uniqueness: true, length: { maximum: 100 }
  validates :tier, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true
  validate :named_for_its_creator

  def self.make!(gallery, name:, by:, tier: nil)
    raise User::PrivilegeError, "Only this creator or an admin can make their groups." unless gallery.managed_by?(by)

    transaction do
      group = create!(creator_gallery: gallery, name: name, tier: tier)
      ModAction.log("created creator group #{group.name}", :creator_group_create, subject: gallery, user: by)
      group
    end
  end

  # Its memberships, requests and audience entries go with it (FK cascade).
  def dissolve!(by:)
    raise User::PrivilegeError, "Only this creator or an admin can dissolve their groups." unless creator_gallery.managed_by?(by)

    transaction do
      ModAction.log("dissolved creator group #{name}", :creator_group_delete, subject: creator_gallery, user: by)
      destroy!
    end
  end

  # Add `user`, or renew their membership: one row per user, so adding again
  # replaces who added it, how and until when. nil expires_at is open-ended.
  #
  # @param source [String] creator (by hand, the creator or an admin),
  #   request (an approved join request) or automation (the system account)
  def add_member!(user, by:, source: CreatorGroupMembership::CREATOR, expires_at: nil)
    authorize_members!(by, source)

    transaction do
      membership = memberships.find_or_initialize_by(user: user)
      membership.update!(added_by: by, source: source, expires_at: expires_at)
      ModAction.log("added user ##{user.id} to creator group #{name} (#{source}#{", until #{expires_at.utc.iso8601}" if expires_at})",
                    :creator_group_member_add, subject: creator_gallery, user: by)
      membership
    end
  end

  def remove_member!(user, by:, source: CreatorGroupMembership::CREATOR)
    authorize_members!(by, source)

    transaction do
      memberships.where(user: user).destroy_all
      ModAction.log("removed user ##{user.id} from creator group #{name} (#{source})", :creator_group_member_remove, subject: creator_gallery, user: by)
    end
  end

  private

  # The creator or an admin by hand; automation only as the system account,
  # and only saying so -- so a row's source never hides who acted.
  def authorize_members!(by, source)
    automation = source == CreatorGroupMembership::AUTOMATION && by.present? && by.name == Danbooru.config.system_user
    return if automation || (source != CreatorGroupMembership::AUTOMATION && creator_gallery.managed_by?(by))

    raise User::PrivilegeError, "Only this creator or an admin can change who is in #{name}; automation acts as the system account."
  end

  def named_for_its_creator
    return if name.blank? || creator_gallery.nil?

    base = master_tag
    return errors.add(:name, "cannot be checked: #{creator_gallery.matrix_id} has no master creator tag to name it for (only an account on #{Danbooru.config.fourier_matrix_server_name} has one)") if base.nil?

    suffix = name.delete_prefix("#{base}_")
    if suffix == name || !suffix.match?(WORDS)
      errors.add(:name, "must be #{base}_ followed by lowercase words joined by single underscores (e.g. #{base}_tier_1 or #{base}_friends)")
    elsif (named_tier = suffix[/\Atier_(\d+)\z/, 1])
      errors.add(:tier, "must be #{named_tier}: the group is named #{name}") unless tier == named_tier.to_i
    elsif tier.present?
      errors.add(:name, "must be #{base}_tier_#{tier} for a tier #{tier} group")
    end
  end

  # "41chan_maple" for @maple:<this homeserver> -- the tag CreatorControl
  # gives them control by, so a namesake on another server, whom that tag
  # does not name, cannot take their group names. nil for any other server.
  def master_tag = CreatorControl.master_tags(creator_gallery.matrix_id).first
end
