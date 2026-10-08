# frozen_string_literal: true

# Deciding a creator claim is an admin act and nothing less (design
# CREATOR_VISIBILITY Q6, ruled 2026-10-07): an approved claim keys a creator's
# control over who sees their posts, and moderators -- who issue TagGrants and
# see nothing a creator hid (Q2) -- must not be able to hand that out.
#
# FILING is not authorized here. Only the person the claim is for may file it,
# and that is proven by the verified Matrix identity header, which no policy
# can see; CreatorGalleriesController#update (claim_tag) gates it on the header and
# the signed-in account together. Every action this policy answers is
# admin-only, so the level scale stays monotonic (permission_matrix_test).
class ArtistClaimPolicy < ApplicationPolicy
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
