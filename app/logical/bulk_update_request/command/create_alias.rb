# frozen_string_literal: true

# Merges tags and creates a permanent redirect from one tag to another.
#
# @see TagAlias
# @see TagMover
class BulkUpdateRequest::Command::CreateAlias < BulkUpdateRequest::Command
  def self.regex
    /\A(?:create alias|alias) (?<old_name>\S+) -> (?<new_name>\S+)\z/i
  end

  def initialize(params)
    @old_name = Tag.normalize_name(params[:old_name])
    @new_name = Tag.normalize_name(params[:new_name])
  end

  def affected_tags
    [@old_name, @new_name]
  end

  def process!(approver:, forum_topic:)
    TagAlias.approve!(antecedent_name: @old_name, consequent_name: @new_name, approver: approver, forum_topic: forum_topic)
  end

  def to_dtext
    "create alias [[#{@old_name}]] -> [[#{@new_name}]]"
  end

  def validate(context:, errors:)
    return if refused_as_claimed_character?(errors)

    tag_alias = TagAlias.new(creator: User.system, antecedent_name: @old_name, consequent_name: @new_name)
    tag_alias.save(context: context)
    if tag_alias.errors.present?
      errors.add(:base, "Can't create alias [[#{tag_alias.antecedent_name}]] -> [[#{tag_alias.consequent_name}]] (#{tag_alias.errors.full_messages.join("; ")})")
    end
  end

  # fourier: an alias or rename moves the tag's posts and its wiki page to the
  # new name (TagMover), which would leave a claimed original character's
  # claim on a name with neither (CharacterClaim, OC ownership 2026-10-11).
  # So the move waits for the claim to end. An alias INTO a claimed tag stays
  # allowed, at admin level (touches_creator_tag?). What TagMover carries
  # along -- <old>_(cosplay), an artist's <old>_(style) -- never holds a
  # claim: CharacterClaim::RESERVED_QUALIFIERS refuses those names.
  #
  # @return [Boolean] true when it refused
  def refused_as_claimed_character?(errors)
    claim = CharacterClaim.standing_on([@old_name]).first
    return false if claim.nil?

    errors.add(:base, "Can't move [[#{@old_name}]] -> [[#{@new_name}]] (#{@old_name} is @#{claim.slug}'s claimed character: " \
                      "an admin withdraws the claim first; the creator files on the new name after the move)")
    true
  end

  def old_tag
    @old_tag ||= Tag.find_by_name(@old_name)
  end

  def new_tag
    @new_tag ||= Tag.find_by_name(@new_name)
  end

  def approval_level(tags: nil)
    return User::Levels::ADMIN if touches_creator_tag? # fourier: creator tags move by admin only

    old_tag = tags.present? ? tags.find { |tag| tag.name == @old_name } : self.old_tag
    new_tag = tags.present? ? tags.find { |tag| tag.name == @new_name } : self.new_tag

    # the old tag is a small artist tag
    old_allowed = old_tag.present? && old_tag.artist? && old_tag.is_small_tag?
    # the new tag doesn't exist, is empty, or is also a small artist tag
    new_allowed = new_tag.blank? || new_tag.empty? || (new_tag.artist? && new_tag.is_small_tag?)

    return User::Levels::BUILDER if old_allowed && new_allowed
    User::Levels::ADMIN
  end
end
