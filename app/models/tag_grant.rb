# frozen_string_literal: true

# A per-user, per-tag grant: one user, one tag, one ability. The whitelist a
# creator's tag carries (operator, 2026-09-04: "a creator allowing other
# users to see their work is, in essence, maintaining a user whitelist on
# their creator tag").
#
# Two abilities, enforced at the two gates that already exist:
#
#   view -- FourierTagSource's privacy gate: the grantee sees the private
#           creator tags on posts carrying the granted tag, exactly as the
#           creator and moderators do.
#   edit -- ArtistClaim.owner?: the grantee edits the one artist the tag
#           names, exactly as an approved claimant does.
#
# Nothing here changes what anyone is DENIED by default; a grant is the only
# way access opens, and revoking the row closes it again.
class TagGrant < ApplicationRecord
  ABILITIES = %w[view edit].freeze

  belongs_to :user
  belongs_to :granter, class_name: "User", foreign_key: :granted_by, optional: true

  normalizes :tag, with: ->(tag) { tag.to_s.strip.downcase.tr(" ", "_") }

  validates :tag, presence: true
  validates :ability, inclusion: { in: ABILITIES }
  validates :tag, uniqueness: { scope: %i[user_id ability] }

  # Does `user` hold `ability` over ANY of `tag_names`?
  def self.granted?(user, tag_names, ability)
    return false if user.nil? || !user.respond_to?(:id) || user.id.nil?

    names = Array(tag_names).map(&:to_s)
    return false if names.empty?

    where(user_id: user.id, ability: ability, tag: names).exists?
  end

  # The tags `user` holds `ability` over, for bulk checks.
  def self.tags_for(user, ability)
    return [] if user.nil? || !user.respond_to?(:id) || user.id.nil?

    where(user_id: user.id, ability: ability).pluck(:tag)
  end
end
