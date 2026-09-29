# frozen_string_literal: true

# A per-user, per-tag grant: one user, one tag, one ability, made by a
# moderator from the admin console. It was meant as the whitelist a creator's
# tag carries (operator, 2026-09-04: "a creator allowing other users to see
# their work is, in essence, maintaining a user whitelist on their creator
# tag") -- but a creator never made one, a moderator did, and since
# 2026-09-29 only the creator decides (see view, below).
#
# Two abilities on record, ONE granted:
#
#   edit -- ArtistClaim.owner?: the grantee edits the one artist the tag
#           names, exactly as an approved claimant does.
#   view -- honoured NOWHERE since round three (2026-09-29), and no longer
#           granted. It once opened a creator's private creator tags, and
#           then only on the creator's own poster tag. But a grant is made
#           by a moderator, and a moderator could grant one to themselves
#           and read a creator's prompts (round-two finding 2), while the
#           ruling is that the creator decides who sees them (operator
#           2026-09-29). FourierCreatorPrivacy reads no grant of any ability.
#           A row already on record stays valid and revocable; nothing new
#           is created with it. Sharing creator-only data needs a control the
#           creator uses, which does not exist yet.
#
# Nothing here changes what anyone is DENIED by default; a grant is the only
# way access opens, and revoking the row closes it again.
class TagGrant < ApplicationRecord
  # Every ability a row on record may carry.
  ABILITIES = %w[view edit].freeze
  # The abilities a NEW grant may carry: the console offers these and nothing
  # else, and the model refuses anything else on create, whoever calls it.
  GRANTABLE = %w[edit].freeze

  belongs_to :user
  belongs_to :granter, class_name: "User", foreign_key: :granted_by, optional: true

  normalizes :tag, with: ->(tag) { tag.to_s.strip.downcase.tr(" ", "_") }

  validates :tag, presence: true
  validates :ability, inclusion: { in: ABILITIES }
  validates :ability, inclusion: { in: GRANTABLE, message: "%{value} is no longer granted: sharing a creator's private data needs a control the creator uses, which does not exist yet" }, on: :create
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
