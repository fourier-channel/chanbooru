# frozen_string_literal: true

class MediaAssetPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    user.is_admin?
  end

  def image?
    can_see_image?
  end

  def can_see_image?
    return false if record.removed?
    # Fork: a posted asset is hidden wherever its post is (Post#hidden_from?)
    # -- deleted, jailed, or gated from a signed-out visitor. Upstream asks
    # only Post#visible?, which never consults is_deleted.
    return !record.post.hidden_from?(user) && record.post.visible?(user) if record.post.present?
    # Fork: an unposted asset is not public -- see
    # Danbooru.config.unposted_media_assets_restricted?.
    return true unless Danbooru.config.unposted_media_assets_restricted?
    user.is_admin? || (!user.is_anonymous? && record.uploads.exists?(uploader_id: user.id))
  end

  def rate_limit_for_image(**_options)
    { rate: 5.0 / 1.second, burst: 50 }
  end

  def api_attributes
    attributes = super + [:variants]
    attributes -= [:md5, :file_key, :variants] if !can_see_image?
    attributes
  end
end
