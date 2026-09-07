# frozen_string_literal: true

# The front page is the site's shop window, so editing it is an admin act.
class LandingSettingPolicy < ApplicationPolicy
  def show?
    user.is_admin?
  end

  def update?
    show?
  end

  def permitted_attributes
    %i[board fresh_only label]
  end
end
