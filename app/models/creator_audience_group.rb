# frozen_string_literal: true

# One group in one audience (design CREATOR_VISIBILITY section 4, "per group
# -- which of the creator's groups see a post or the default"). post_id NULL
# is the creator default; a post id is that creator's override on the post.
# A tiered group here admits its higher tiers too (Q3); that, like
# everything else these rows mean, is CreatorVisibility's.
class CreatorAudienceGroup < ApplicationRecord
  # The audiences that list no groups: inherit has none of its own, and
  # private is the creator alone (section 4).
  GROUPLESS = %w[inherit private].freeze

  belongs_to :creator_group
  belongs_to :post, optional: true

  # Replace the groups of one audience -- `gallery`'s default when `post` is
  # nil, otherwise `gallery`'s override on the post -- with `group_ids`. The
  # only writer, called inside the logged write of the audience itself. A
  # group that is not this creator's, or any group under an audience that
  # lists none, is refused, loudly, rather than dropped or stored: an
  # audience that silently lost a group, or a group logged as granted that
  # grants nothing, is not what its creator chose.
  #
  # @return [Array<String>] the names of the groups now in the audience
  def self.replace!(gallery, post, audience, group_ids)
    ids = Array(group_ids).map(&:to_i).uniq
    if audience.in?(GROUPLESS) && ids.any?
      raise ArgumentError, "an audience of #{audience} lists no groups (#{(audience == "private") ? "private is the creator alone" : "inherit takes the creator default's"})"
    end

    groups = CreatorGroup.where(id: ids, creator_gallery_id: gallery.id).order(:name).pluck(:id, :name)
    foreign = ids - groups.map(&:first)
    if foreign.any?
      raise ArgumentError, "group #{foreign.join(", ")} is not a group of creator #{gallery.matrix_id}: " \
                           "an audience can include only its creator's own groups"
    end

    # Only this creator's groups go: another controller's override on the
    # same post keeps its own.
    where(post_id: post&.id, creator_group_id: gallery.creator_groups.select(:id)).delete_all
    groups.map(&:first).each { |id| create!(creator_group_id: id, post: post) }
    groups.map(&:second)
  end
end
