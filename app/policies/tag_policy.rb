# frozen_string_literal: true

class TagPolicy < ApplicationPolicy
  # POST /tags exists only to pre-flag a name (TagsController#create).
  def create?
    can_change_quarantine?
  end

  def can_change_category?
    return false if record.artist.present? && record.category == Tag.categories.artist
    # Fork: a claimed original character stays a character unless an admin
    # re-files it (CharacterClaim, OC ownership 2026-10-11).
    return user.is_admin? if CharacterClaim.claimed?([record.name])
    return true if user.is_admin?
    return true if user.is_builder? && record.post_count < 1_000
    record.post_count < 50
  end

  def can_change_deprecated_status?
    return false if (record.wiki_page.blank? || record.wiki_page.is_deleted?) && !record.is_deprecated?

    user.is_admin?
  end

  # Flag a tag for review, release it, or banish it (TagQuarantine, operator
  # rulings 2026-10-12): Admin level and up (Owner included).
  def can_change_quarantine?
    user.is_admin?
  end

  def permitted_attributes
    permitted = []
    permitted << :category if can_change_category?
    permitted << :is_deprecated if can_change_deprecated_status?
    permitted += [:quarantine, :quarantine_note] if can_change_quarantine?
    permitted
  end
end
