# frozen_string_literal: true

# Minting a registration token is handing someone the key to the site, so it is
# an admin act and nothing less.
class SignupTokenPolicy < ApplicationPolicy
  def index?
    user.is_admin?
  end

  def create?
    index?
  end

  def revoke?
    index?
  end

  def permitted_attributes
    %i[token note usage_limit expires_at]
  end
end
