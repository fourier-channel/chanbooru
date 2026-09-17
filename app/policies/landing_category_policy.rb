# frozen_string_literal: true

# A carousel category is part of the front page, so editing one is an admin act
# -- the same rule, for the same reason, as LandingSettingPolicy.
class LandingCategoryPolicy < ApplicationPolicy
  def show?
    user.is_admin?
  end

  def update?
    show?
  end

  # KIND AND POSITION ARE NOT HERE, deliberately. `kind` decides which code
  # path a row runs -- a board search, a tag search, or the promoted galleries
  # -- and which fields even apply to it; it is structure, not configuration,
  # and it comes from LandingCategory::DEFAULTS. An admin who could retype it
  # could turn "Fresh from DEGEN" into a galleries row with a board still set
  # on it, which the model would then have to reject in a form that has no
  # field to point the error at.
  def permitted_attributes
    %i[enabled label board fresh_only tags_string ordering]
  end
end
