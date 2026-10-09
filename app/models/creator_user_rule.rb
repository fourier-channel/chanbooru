# frozen_string_literal: true

# A named user allowed or blocked by a creator, across all their posts
# (post_id NULL) or on one post (design CREATOR_VISIBILITY section 4: "named
# users allowed, and named users blocked. A block beats every allow"; Q8,
# ruled 2026-10-07: a block stops the signed-in account seeing, and so
# editing, the post). What a rule means is CreatorVisibility's.
#
# A rule that could change nothing is refused (creator panel, 2026-10-09;
# fail loudly, 2026-09-13): on the creator's own account, which always sees
# its posts, and on an admin or a posting account, who see every post
# (CreatorVisibility.sees_everything?, the decision's own "who always
# sees"). Saving the same rule again, or clearing one that is not there,
# writes and logs nothing.
#
# One rule per user and scope: setting allow where a block stood replaces it.
# A creator-wide rule and a per-post rule are separate scopes, both read --
# which is how a block anywhere beats an allow anywhere.
class CreatorUserRule < ApplicationRecord
  ALLOW = "allow"
  BLOCK = "block"
  RULES = [ALLOW, BLOCK].freeze

  belongs_to :creator_gallery
  belongs_to :user
  belongs_to :post, optional: true
  belongs_to :updated_by, class_name: "User"

  validates :rule, inclusion: { in: RULES }
  validate :gallery_controls_post
  validate :rule_can_matter

  # @return [CreatorUserRule, nil] the rule; nil when it already was this
  def self.set!(gallery, user, rule:, by:, post: nil)
    authorize!(gallery, by)

    transaction do
      row = find_or_initialize_by(creator_gallery: gallery, user: user, post: post)
      next nil if row.persisted? && row.rule == rule

      row.update!(rule: rule, updated_by: by)
      ModAction.log("#{(rule == BLOCK) ? "blocked" : "allowed"} user ##{user.id} #{scope_words(gallery, post)}",
                    :creator_user_rule_update, subject: post || gallery, user: by)
      row
    end
  end

  # @return [Boolean] false when there was no rule to clear
  def self.clear!(gallery, user, by:, post: nil)
    authorize!(gallery, by)

    transaction do
      next false if where(creator_gallery: gallery, user: user, post: post).destroy_all.empty?

      ModAction.log("cleared the rule for user ##{user.id} #{scope_words(gallery, post)}", :creator_user_rule_update, subject: post || gallery, user: by)
      true
    end
  end

  def self.authorize!(gallery, by)
    raise User::PrivilegeError, "Only this creator or an admin can allow or block users on their posts." unless gallery.managed_by?(by)
  end

  def self.scope_words(gallery, post)
    post ? "on post ##{post.id} of creator #{gallery.matrix_id}" : "on every post of creator #{gallery.matrix_id}"
  end

  private

  def rule_can_matter
    return if user.nil? || creator_gallery.nil?

    if creator_gallery.user_id == user.id
      errors.add(:base, "You always see your own posts.")
    # Exactly the decision's own exemption, on the list visibility reads
    # (repair, 2026-10-09): that list keeps its last good copy when the file
    # breaks, so a block the decision would honour is never refused here.
    elsif CreatorVisibility.sees_everything?(user)
      errors.add(:base, "#{user.name} is an admin or a posting account and sees every post, so a rule on them changes nothing.")
    end
  end

  def gallery_controls_post
    return if post.nil? || creator_gallery_id.nil?
    return if CreatorControl.controller_gallery_ids([post]).fetch(post.id).include?(creator_gallery_id)

    errors.add(:base, "creator #{creator_gallery&.matrix_id} does not control post ##{post.id}: a creator names users only on their own posts")
  end
end
