# frozen_string_literal: true

class ModActionPolicy < ApplicationPolicy
  def show?
    category = record.category.to_sym
    return user.is_admin? if category.in?(ModAction::ADMIN_ONLY_CATEGORIES)

    user.is_moderator? || !category.in?(ModAction::MOD_ONLY_CATEGORIES)
  end

  def api_attributes
    super + [:category_id]
  end
end
