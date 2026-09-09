# frozen_string_literal: true

# A token that permits ONE account creation, or several, or unlimited.
#
# 41chan is not an open site: before this, signup was closed outright and
# accounts were made by hand. This is the middle setting the operator asked
# for -- trusted people can register themselves, strangers cannot -- and it is
# modelled on MAS's registration tokens so that the Matrix side and the booru
# side work the same way.
#
# The security property that matters is the DEFAULT. Every predicate here is
# written so that the absence of a good reason means refusal: an unknown token
# is invalid, a blank token is invalid, and `redeem!` raises rather than
# returning false, so a caller that forgets to check cannot quietly proceed.
class SignupToken < ApplicationRecord
  class InvalidTokenError < StandardError; end

  TOKEN_LENGTH = 12

  attribute :token, default: -> { SignupToken.generate_token }

  belongs_to :creator, class_name: "User"

  validates :token, presence: true, uniqueness: true, length: { minimum: 4, maximum: 200 }
  validates :usage_limit, numericality: { greater_than: 0, allow_nil: true }

  def self.generate_token
    SecureRandom.alphanumeric(TOKEN_LENGTH)
  end

  # Unambiguous lookup. Tokens are compared whole and case-sensitively; a
  # trimmed copy-paste is forgiven because that is a transcription artefact
  # rather than a different secret.
  def self.for(raw)
    return nil if raw.blank?
    find_by(token: raw.to_s.strip)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def exhausted?
    usage_limit.present? && times_used >= usage_limit
  end

  def usable?
    !revoked? && !expired? && !exhausted?
  end

  def status
    return "revoked" if revoked?
    return "expired" if expired?
    return "used up" if exhausted?
    "usable"
  end

  def remaining
    usage_limit.nil? ? Float::INFINITY : [usage_limit - times_used, 0].max
  end

  # Spend one use. Raises unless the token is usable, so a caller cannot treat
  # a refusal as success by ignoring a return value.
  #
  # The increment is atomic and re-checks the limit inside the same statement:
  # two people redeeming the last use of a token at once must not both get in.
  def redeem!
    raise InvalidTokenError, "that token is #{status}" unless usable?

    updated =
      if usage_limit.nil?
        self.class.where(id: id).where(revoked_at: nil).update_all("times_used = times_used + 1")
      else
        self.class.where(id: id).where(revoked_at: nil)
            .where("times_used < ?", usage_limit)
            .update_all("times_used = times_used + 1")
      end
    raise InvalidTokenError, "that token is no longer usable" if updated.zero?

    reload
    true
  end

  def revoke!(by:)
    update!(revoked_at: Time.current) unless revoked?
  end

  def self.visible(user)
    user.is_admin? ? all : none
  end
end
