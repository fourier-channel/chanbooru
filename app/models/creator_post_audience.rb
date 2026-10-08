# frozen_string_literal: true

# One post's own audience, overriding its creator's default (design
# CREATOR_VISIBILITY section 4 and Q4, built as recommended 2026-10-07):
# inherit (the default decides), public, groups (with the post's own groups,
# CreatorAudienceGroup) or private.
#
# One row per post AND controlling gallery. A post with two controllers
# (section 9: "two claimants on one post: narrowest wins") keeps each one's
# own setting, so neither can write over the other's -- a single shared row
# let the second claimant erase the first's private. A row counts only while
# its gallery controls the post, so a claim withdrawn later does not leave
# its holder's choice in force (CreatorVisibility reads it that way).
class CreatorPostAudience < ApplicationRecord
  AUDIENCES = %w[inherit public groups private].freeze

  belongs_to :post
  belongs_to :creator_gallery
  belongs_to :updated_by, class_name: "User"

  validates :audience, inclusion: { in: AUDIENCES }
  validate :gallery_controls_post

  # Set `post`'s audience as `gallery`, with its groups, in one logged write.
  def self.set!(post, gallery:, audience:, by:, group_ids: [])
    raise User::PrivilegeError, "Only this creator or an admin can set who sees their posts." unless gallery.managed_by?(by)

    transaction do
      row = find_or_initialize_by(post: post, creator_gallery: gallery)
      row.update!(audience: audience, updated_by: by)
      names = CreatorAudienceGroup.replace!(gallery, post, audience, group_ids)
      ModAction.log("set the audience of post ##{post.id} to #{audience} for creator #{gallery.matrix_id}#{" (groups: #{names.join(", ")})" if names.any?}",
                    :creator_audience_update, subject: post, user: by)
      row
    end
  end

  private

  def gallery_controls_post
    return if post.nil? || creator_gallery_id.nil?
    return if CreatorControl.controller_gallery_ids([post]).fetch(post.id).include?(creator_gallery_id)

    errors.add(:base, "creator #{creator_gallery&.matrix_id} does not control post ##{post.id}: a creator sets the audience only of their own posts")
  end
end
