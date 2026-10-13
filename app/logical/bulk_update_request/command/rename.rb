# frozen_string_literal: true

# Just like an alias, but without permanent redirect.
#
# @see TagMover
class BulkUpdateRequest::Command::Rename < BulkUpdateRequest::Command::CreateAlias
  # Rename can only be used for tags containing up to this amount of posts
  MAXIMUM_RENAME_COUNT = 200

  def self.regex
    /\Arename (?<old_name>\S+) -> (?<new_name>\S+)\z/i
  end

  # fourier: a LEGACY original-character tag (oc_<name> and its shapes) is
  # moved as an alias, not a bare rename (2026-10-12). Old images' prompts
  # still say oc_kayla, and with no redirect left the hub would declare
  # oc_kayla as itself again on the next one, splitting the character in two
  # and missing the ownership the move settled. The alias runs the same
  # TagMover, so the move and its ownership are otherwise identical.
  def process!(approver:, **)
    if FourierTagSource.legacy_original_character(@old_name)
      TagAlias.approve!(antecedent_name: @old_name, consequent_name: @new_name, approver: approver)
    else
      TagMover.new(@old_name, @new_name, approver: approver).move!
    end
  end

  def to_dtext
    "rename [[#{@old_name}]] -> [[#{@new_name}]]"
  end

  def validate(errors:, **)
    return if refused_as_claimed_character?(errors) || refused_ownership?(errors)

    refusal = TagAlias.quarantine_move_refusal(@old_name, @new_name)
    return errors.add(:base, "Can't rename [[#{@old_name}]] -> [[#{@new_name}]] (#{refusal})") if refusal

    new_tag ||= Tag.new(name: @new_name)

    if old_tag.nil?
      errors.add(:base, "Can't rename [[#{@old_name}]] -> [[#{@new_name}]] ([[#{@old_name}]] doesn't exist)")
    elsif old_tag.post_count > MAXIMUM_RENAME_COUNT
      errors.add(:base, "Can't rename [[#{@old_name}]] -> [[#{@new_name}]] ([[#{@old_name}]] has more than #{MAXIMUM_RENAME_COUNT} posts, use an alias instead)")
    elsif new_tag.invalid?(:name)
      errors.add(:base, "Can't rename [[#{@old_name}]] -> [[#{@new_name}]] (#{new_tag.errors.full_messages.join("; ")})")
    elsif reversed_alias.present?
      # Aliases are allowed to be reversed this way, but renames aren't.
      errors.add(:base, "Can't rename [[#{@old_name}]] -> [[#{@new_name}]] ([[#{@new_name}]] is aliased to [[#{@old_name}]], use an alias to reverse it instead)")
    end
  end

  def reversed_alias
    TagAlias.active.find_by(antecedent_name: @new_name, consequent_name: @old_name)
  end
end
