# frozen_string_literal: true

# A creator tag released from its prefix's default visibility -- see the
# migration for the ruling. While CreatorPrefixes hides a prefix (aichan_:
# admins only), a released creator's posts are governed by their own tag:
# public, until the creator control panel (CREATOR_VISIBILITY.md) narrows it.
#
# Who may release: an admin, or the creator themselves through an APPROVED
# claim on that exact tag. Not ArtistClaim.owner?, which also reads a
# moderator-issued edit TagGrant -- a moderator must not be able to grant
# themselves a creator and release them.
#
# Logged as a ModAction that does NOT name the tag: mod actions are readable
# below admin, and the name of a hidden creator is part of what is hidden.
# The row itself (updater, note, timestamps) is the admin-only record.
class CreatorTagRelease < ApplicationRecord
  belongs_to :updater, class_name: "User"

  validates :tag_name, presence: true, uniqueness: true, length: { maximum: 170 }
  validate :under_a_listed_prefix

  normalizes :note, with: ->(note) { note.to_s.strip.truncate(500) }

  @mutex = Mutex.new
  @released = nil

  # The released tag names, as a Set. Cached on the table's own stamp (the
  # newest change and the row count), never a timer: a release is live on the
  # next request.
  def self.released_names
    stamp = [maximum(:updated_at), count]
    @mutex.synchronize do
      return @released[:value] if @released && @released[:stamp] == stamp
    end
    value = where(released: true).pluck(:tag_name).to_set.freeze
    @mutex.synchronize { @released = { stamp: stamp, value: value } }
    value
  end

  def self.reset_cache!
    @mutex.synchronize { @released = nil }
  end

  # The creator themselves: an approved claim on this tag, on a gallery that is
  # theirs, still standing (ArtistClaim.standing). Keyed on the claim's
  # tag_name, never the Artist's current name, which any member can change
  # (CREATOR_VISIBILITY section 9: renaming an Artist moves nothing).
  def self.owner?(user, tag_name)
    owned_names(user).include?(tag_name.to_s)
  end

  # The tags `user` holds an approved claim on: they see their own posts.
  def self.owned_names(user)
    return Set.new if user.nil? || user.is_anonymous?

    ArtistClaim.held_by(user).standing.to_set(&:first)
  end

  def self.may_set?(user, tag_name)
    return false if user.nil? || user.is_anonymous?

    user.is_admin? || owner?(user, tag_name)
  end

  def self.set!(tag_name, released:, by:, note: "")
    raise User::PrivilegeError unless may_set?(by, tag_name)

    row = find_or_initialize_by(tag_name: tag_name.to_s)
    changed = row.new_record? || row.released != released
    row.update!(released: released, updater: by, note: note)
    if changed
      # No subject: /mod_actions links every row's subject, and a release has
      # no page to link to (the admin's list is releases_creator_prefixes).
      ModAction.log("changed a hidden creator's visibility (creator release ##{row.id})", :creator_visibility_update, subject: nil, user: by)
    end
    row
  end

  private

  def under_a_listed_prefix
    errors.add(:tag_name, "#{tag_name} carries no listed creator prefix") unless CreatorPrefixes.locked?(tag_name)
  rescue CreatorPrefixes::ConfigError => e
    errors.add(:base, e.message)
  end
end
