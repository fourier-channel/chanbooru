# frozen_string_literal: true

class PostReplacementPolicy < ApplicationPolicy
  include PostingAccounts::Policy

  # Fork: a replacement makes a post's content from a new file or URL, so it
  # is posting -- the posting bots only (PostingAccounts, operator ruling
  # 2026-10-07), and of them only a moderator, as upstream asks. No bot is a
  # moderator, so today nobody replaces a file.
  def create?
    user.is_moderator? && may_post?
  end

  def update?
    user.is_moderator?
  end

  def permitted_attributes_for_create
    %i[replacement_url replacement_file final_source tags]
  end

  def permitted_attributes_for_update
    %i[
      old_file_ext old_file_size old_image_width old_image_height old_md5
      file_ext file_size image_width image_height md5 original_url
      replacement_url
    ]
  end
end
