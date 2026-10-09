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
# whose group it is and how it nests, and two creators cannot share one --
# nor can one creator's name read as another's (another_creators_name?).
#
# ONE GAP STAYS, FOR AN ADMIN (second repair, 2026-10-09). Names are unique
# site-wide (a unique index), and a creator the booru does not know yet --
# no page, no recorded post -- cannot be recognised, so a group can be made
# in their name first. When their page is made, CreatorGallery closes such a
# group to requests and logs it for an admin to settle, and it cannot be
# opened again while its name reads as theirs. Uniqueness per creator would
# close the gap outright, but it swaps the unique index (not additive), so it
# is the operator's question, not this file's.
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

  # The house rule first: a name refused for reading as another creator's
  # is never also asked whether it is taken, so a refusal cannot tell one
  # creator whether another has a group of that name (repair, 2026-10-09).
  # A name that passes it is in the maker's own name, so who holds it may be
  # said: the maker, or a group made in their name before they were known.
  validate :named_for_its_creator
  validates :name, presence: true, length: { maximum: 100 }
  validate :name_free, unless: -> { errors.key?(:name) }
  validates :tier, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true

  # A group as the panel, its notices and the post page name it: a tier
  # group says that every higher tier sees what it sees (Q3), which is what
  # CreatorVisibility enforces.
  def self.label(name, tier) = tier ? "#{name} (and every higher tier)" : name

  def label = self.class.label(name, tier)

  # `open_to_requests`: whether visitors may ask to join from the creator's
  # page (Q5). Off unless the creator says so: a group run by hand is never
  # named to visitors (creator panel, 2026-10-09).
  def self.make!(gallery, name:, by:, tier: nil, open_to_requests: false)
    raise User::PrivilegeError, "Only this creator or an admin can make their groups." unless gallery.managed_by?(by)

    transaction do
      group = create!(creator_gallery: gallery, name: name, tier: tier, open_to_requests: open_to_requests)
      ModAction.log("created creator group #{group.name}#{" (open to requests)" if group.open_to_requests}", :creator_group_create, subject: gallery, user: by)
      group
    end
  end

  # Open the group to join requests from the creator's page, or close it.
  # A request already waiting stays for the creator to decide.
  #
  # @return [CreatorGroup, nil] nil when it already was as asked (nothing
  #   written, nothing logged)
  #
  # A group whose name reads as another creator's is never opened: visitors
  # would ask the wrong creator (second repair, 2026-10-09).
  def open_to_requests!(open, by:)
    raise User::PrivilegeError, "Only this creator or an admin can choose who may ask to join their groups." unless creator_gallery.managed_by?(by)
    return nil if open_to_requests == open

    if open && reads_as_another_creator?
      base = master_tag
      errors.add(:base, "#{name} reads as another creator's name, so it cannot be opened to requests. Make a group named for you instead, like #{base}_tier_1 or #{base}_friends.")
      raise ActiveRecord::RecordInvalid, self
    end

    transaction do
      update!(open_to_requests: open)
      ModAction.log("#{open ? "opened" : "closed"} creator group #{name} to requests", :creator_group_update, subject: creator_gallery, user: by)
      self
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
  # replaces who added it, how and until when. nil expires_at is open-ended;
  # a date already gone is refused (CreatorGroupMembership).
  #
  # AUTOMATION NEVER UNDOES THE CREATOR'S HAND (section 5: automation drives
  # these same methods, so the guard lives here, not in its caller). An
  # automation add over an active membership the creator made, or let in by
  # request, leaves it exactly as it is -- a sign-up provider renewing a
  # subscription must not put an expiry on someone the creator added for
  # good -- and says so in the log. approve! keeps an existing membership
  # the same way.
  #
  # @param source [String] creator (by hand, the creator or an admin),
  #   request (an approved join request) or automation (the system account)
  # @return [CreatorGroupMembership, nil] the membership; nil when it already
  #   was exactly this (nothing written, nothing logged)
  def add_member!(user, by:, source: CreatorGroupMembership::CREATOR, expires_at: nil)
    authorize_members!(by, source)
    # At the column's precision, so the same date again is no change: the
    # panel's end_of_day carries nanoseconds the column does not keep.
    expires_at = expires_at&.floor(6)

    transaction do
      membership = memberships.find_or_initialize_by(user: user)
      if source == CreatorGroupMembership::AUTOMATION && membership.persisted? && membership.manual? && membership.active?
        ModAction.log("automation left user ##{user.id} in creator group #{name} unchanged (added by hand)", :creator_group_member_add, subject: creator_gallery, user: by)
        next membership
      end
      next nil if membership.persisted? && membership.source == source && membership.expires_at == expires_at

      membership.update!(added_by: by, source: source, expires_at: expires_at)
      ModAction.log("added user ##{user.id} to creator group #{name} (#{source}#{", until #{expires_at.utc.iso8601}" if expires_at})",
                    :creator_group_member_add, subject: creator_gallery, user: by)
      membership
    end
  end

  # Automation removes only what automation added: a member the creator added,
  # or let in by request, is the creator's to remove (section 5).
  #
  # @return [Boolean] false when `user` was not in the group (nothing logged)
  def remove_member!(user, by:, source: CreatorGroupMembership::CREATOR)
    authorize_members!(by, source)

    transaction do
      membership = memberships.find_by(user: user)
      next false if membership.nil?

      if source == CreatorGroupMembership::AUTOMATION && membership.source != CreatorGroupMembership::AUTOMATION
        raise User::PrivilegeError, "#{user.name} was added to #{name} by the creator, not by automation. Only the creator removes them."
      end

      membership.destroy!
      ModAction.log("removed user ##{user.id} from creator group #{name} (#{source})", :creator_group_member_remove, subject: creator_gallery, user: by)
      true
    end
  end

  # Whether this group's name, made earlier, now reads as another creator's
  # -- one the booru has come to know since (CreatorGallery asks on a new page).
  def reads_as_another_creator?
    base = master_tag
    base.present? && name.start_with?("#{base}_") && another_creators_name?(base, name.delete_prefix("#{base}_"))
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
    elsif will_save_change_to_name? && another_creators_name?(base, suffix)
      errors.add(:name, "#{name} reads as another creator's name. Choose a name that starts with a word of your own after #{base}_, like #{base}_tier_1 or #{base}_friends.")
    elsif (named_tier = suffix[/\Atier_(\d+)\z/, 1])
      errors.add(:tier, "must be #{named_tier}: the group is named #{name}") unless tier == named_tier.to_i
    elsif tier.present?
      errors.add(:name, "must be #{base}_tier_#{tier} for a tier #{tier} group")
    end
  end

  # ONE NAME, ONE CREATOR (repair, 2026-10-09). Matrix localparts may hold
  # underscores, so @sab's tag plus "er_tier_1" spells 41chan_sab_er_tier_1,
  # @sab_er's tier 1. A name is refused when any run of its words after the
  # maker's own tag is another creator's master tag -- a creator the booru
  # knows by a page (creator_galleries) or by a post the posting bot
  # recorded as theirs (fourier_post_creators, from the authenticated
  # sender). Never by a bare Tag: any member can make one through an artist
  # entry, which let anyone deny a creator their tier names (second repair,
  # 2026-10-09). Checked when the name is set, not on every later save.
  def another_creators_name?(base, suffix)
    words = suffix.split("_")
    tags = words.each_index.map { |i| "#{base}_#{words[..i].join("_")}" }
    prefix = base.delete_suffix(ArtistClaim.localpart(creator_gallery.matrix_id).to_s.downcase)
    mxids = tags.map { |tag| "@#{tag.delete_prefix(prefix)}:#{Danbooru.config.fourier_matrix_server_name}".downcase }
    CreatorGallery.where.not(id: creator_gallery_id).exists?(["lower(matrix_id) IN (?)", mxids]) ||
      FourierPostCreator.exists?(["lower(mxid) IN (?)", mxids])
  end

  # The unique index's question, asked in words with a remedy. The database
  # still decides a race (the panel answers RecordNotUnique).
  def name_free
    holder = CreatorGroup.where(name: name).where.not(id: id).pick(:creator_gallery_id)
    if holder == creator_gallery_id
      errors.add(:name, "#{name} is already one of your groups; it is listed under Your groups.")
    elsif holder
      errors.add(:name, "#{name} is held by another creator's group, made before your page or posts were known here. " \
                        "An admin settles whose it is: ask one, or choose another name.")
    end
  end

  # "41chan_maple" for @maple:<this homeserver> -- the tag CreatorControl
  # gives them control by, so a namesake on another server, whom that tag
  # does not name, cannot take their group names. nil for any other server.
  def master_tag = CreatorControl.master_tags(creator_gallery.matrix_id).first
end
