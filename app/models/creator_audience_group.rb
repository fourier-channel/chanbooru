# frozen_string_literal: true

# One group in one audience (design CREATOR_VISIBILITY section 4, "per group
# -- which of the creator's groups see a post or the default"). post_id NULL
# is the creator default; a post id is that creator's override on the post.
# A tiered group here admits its higher tiers too (Q3); that, like
# everything else these rows mean, is CreatorVisibility's.
class CreatorAudienceGroup < ApplicationRecord
  # The audiences that list no groups: inherit has none of its own, and no
  # group ever opens private (Q9, 2026-10-07: the users named, and nobody else).
  GROUPLESS = %w[inherit private].freeze

  # A refusal of the groups asked for: an ArgumentError, so every caller that
  # already expected one still does, and narrow enough that the creator panel
  # rescues only this and never an ArgumentError from somewhere else.
  class Refusal < ArgumentError; end

  belongs_to :creator_group
  belongs_to :post, optional: true

  # Replace the groups of one audience -- `gallery`'s default when `post` is
  # nil, otherwise `gallery`'s override on the post -- with `group_ids`. The
  # only writer, called inside the logged write of the audience itself. A
  # group that is not this creator's, or any group under an audience that
  # lists none, is refused, loudly, rather than dropped or stored: an
  # audience that silently lost a group, or a group logged as granted that
  # grants nothing, is not what its creator chose. So is "groups" with no
  # group (creator panel, 2026-10-09): it would show the posts to the named
  # users alone, which is what private says, under a name that says
  # otherwise. Dissolving a group can still leave one behind (the database
  # cascades); the panel warns about that state, as it cannot refuse it.
  #
  # @return [Array<String>] the names of the groups now in the audience
  def self.replace!(gallery, post, audience, group_ids)
    ids = refuse!(audience, group_ids)
    groups = CreatorGroup.where(id: ids, creator_gallery_id: gallery.id).order(:name).pluck(:id, :name)
    foreign = ids - groups.map(&:first)
    if foreign.any?
      raise Refusal, "group #{foreign.join(", ")} is not a group of creator #{gallery.matrix_id}: " \
                     "an audience can include only its creator's own groups"
    end

    # Only this creator's groups go: another controller's override on the
    # same post keeps its own.
    where(post_id: post&.id, creator_group_id: gallery.creator_groups.select(:id)).delete_all
    groups.map(&:first).each { |id| create!(creator_group_id: id, post: post) }
    groups.map(&:second)
  end

  # The refusals that hang on the choice alone, asked by each writer BEFORE
  # it compares with what is stored: a choice that would be refused is
  # refused even when it is what is stored already (a default left on
  # groups-with-none by a dissolved group), never answered "Nothing changed"
  # (second repair, 2026-10-09).
  #
  # @return [Array<Integer>] the group ids asked for, unique
  def self.refuse!(audience, group_ids)
    ids = Array(group_ids).map(&:to_i).uniq
    if audience == "groups" && ids.empty?
      raise Refusal, "Members of my groups needs at least one group ticked. With none, only the people you name could see these posts; choose Private for that."
    end
    if audience.in?(GROUPLESS) && ids.any?
      raise Refusal, "an audience of #{audience} lists no groups (#{(audience == "private") ? "no group opens a private post; name its users instead" : "inherit takes the creator default's"})"
    end

    ids
  end

  # The group ids of one audience as stored -- what a writer compares with,
  # so saving the same choice again writes and logs nothing.
  def self.current_ids(gallery, post)
    where(post_id: post&.id, creator_group_id: gallery.creator_groups.select(:id)).pluck(:creator_group_id).sort
  end
end
