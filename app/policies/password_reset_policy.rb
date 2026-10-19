# frozen_string_literal: true

class PasswordResetPolicy < ApplicationPolicy
  def show?
    user.is_anonymous?
  end

  def create?
    user.is_anonymous?
  end

  def update?
    user.is_anonymous?
  end

  # Fork: the one-time password link (PasswordReveal) opens for whoever holds
  # it, signed in or not. The token is the whole authority -- whoever holds it
  # could open it signed out anyway -- and showing the password neither signs
  # the viewer in nor touches their session, so refusing a signed-in viewer
  # would protect nothing and strand a person signed in to another account on
  # the same browser. Rate-limited as update is (rate_limit_for_update).
  def reveal?
    true
  end

  def rate_limit_for_create(**_options)
    { rate: 1.0 / 1.minute, burst: 5 }
  end

  def rate_limit_for_update(**_options)
    { rate: 1.0 / 30.minutes, burst: 50 }
  end
end
