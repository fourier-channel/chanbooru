# frozen_string_literal: true

# WHO MADE A POST: the Matrix account that posted it, recorded once, at post
# creation, by the posting bot (operator ruling 2026-09-29). The one input
# FourierCreatorPrivacy trusts for "is this viewer the creator".
#
# Written by POST /fourier/posts/:post_id/creator.json
# (FourierPostCreatorsController) from the AUTHENTICATED sender of the Matrix
# event, and by FourierCreatorBackfill for posts made before this existed.
# Never from the post's tags: a 41chan_<localpart> tag is something any member
# can add to any post, so it proves nothing.
#
# One row per post, never overwritten. A second recording that names the same
# account is a no-op; one that names a different account is refused.
class FourierPostCreator < ApplicationRecord
  # A Matrix user id: @localpart:server. No whitespace, no control characters
  # (a NUL in a string column is a 500 from the database, not a 422), at most
  # 255 characters as the Matrix spec caps a user id.
  MXID = /\A@[^:\s\x00-\x1f\x7f]+:[^\s\x00-\x1f\x7f]+\z/
  MAX_MXID_LENGTH = 255

  belongs_to :post
  belongs_to :recorder, class_name: "User", foreign_key: :recorded_by

  # post_id is unique by its index alone. A uniqueness validation here would
  # turn the race record! handles into a RecordInvalid it does not.
  validates :mxid, format: { with: MXID }, length: { maximum: MAX_MXID_LENGTH }

  def self.valid_mxid?(mxid)
    mxid.is_a?(String) && mxid.length <= MAX_MXID_LENGTH && mxid.match?(MXID)
  end

  # Two MXIDs are the same account when they match case-insensitively, as
  # FourierIdentity.matches? compares them.
  def self.same_mxid?(left, right)
    left.present? && right.present? && left.casecmp?(right)
  end

  # Record `mxid` as the creator of `post`, unless a creator is already on
  # record. Returns the row that stands -- this one, or the one before it --
  # so the caller compares its mxid to decide between "done" and "conflict".
  # A second writer racing for the same post loses the unique index and gets
  # the winner's row back.
  def self.record!(post, mxid, recorded_by)
    find_by(post_id: post.id) || create!(post: post, mxid: mxid, recorded_by: recorded_by.id)
  rescue ActiveRecord::RecordNotUnique
    find_by!(post_id: post.id)
  end
end
