# frozen_string_literal: true

# Deciding an original character claim that was not clean enough to approve
# itself is an admin's act (OC ownership, ruled 2026-10-11, Q2), in the same
# queue as creator claims. FILING is not authorized here: only the creator the
# claim is for may file or release it, proven by the verified Matrix identity
# header no policy can see (CreatorGalleriesController). Every action this
# policy answers is admin-only, so the level scale stays monotonic
# (permission_matrix_test).
class CharacterClaimPolicy < ApplicationPolicy
  def index?
    user.is_admin?
  end

  def create?
    index?
  end

  def update?
    index?
  end

  def approve?
    index?
  end

  def reject?
    index?
  end
end
