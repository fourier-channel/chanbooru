# frozen_string_literal: true

# WHO MAY POST: the site's ingest bots, and nobody else.
#
# Operator ruling 2026-10-07: "The upload path is only ever used by the bots.
# Normal users are not intended to be able to post directly." Measured on
# production that day: exactly two accounts have ever created an upload --
# `sample` (fourier-sampling: POST /uploads.json, then POST /posts.json) and
# `tunnel` (fourier-tunnel, the same two calls). Upstream lets any unbanned
# member upload (UploadPolicy#create? was `unbanned?`).
#
# The list is Danbooru.config.fourier_posting_bot_names -- the same list that
# already says which accounts post on someone else's behalf, because it is the
# same fact. Empty or missing means nobody may post (fail closed), and the
# refusal names the setting so the fix is in the message.
#
# Asked by every door that makes content from a file or a URL, through the
# policies that include PostingAccounts::Policy: UploadPolicy#create? (POST
# /uploads, GET /uploads/new), PostPolicy#create? (POST /posts from an upload
# media asset, GET /posts/new) and PostReplacementPolicy#create? (POST
# /post_replacements, GET /post_replacements/new). A refused account gets a
# 403 that says posting is done by the site's ingest, not by hand
# (ApplicationController#rescue_exception reads denial_message). Tag edits,
# votes, favorites and the rest are NOT posting and are untouched: Technetium
# edits tags as a signed-in member.
module PostingAccounts
  SETTING = "Danbooru.config.fourier_posting_bot_names"

  module_function

  # The account names that may post, lowercased; [] when none are configured.
  def names
    Array(Danbooru.config.fourier_posting_bot_names).map { |name| name.to_s.strip.downcase }.compact_blank
  end

  def may_post?(user)
    return true unless Danbooru.config.posting_restricted_to_bots?
    return false if user.nil? || user.is_anonymous?

    allowed = names
    Rails.logger.error("[posting_accounts] #{SETTING} is empty: nobody may post") if allowed.empty?
    allowed.include?(user.name.to_s.downcase)
  end

  # What a refused account is told.
  def refusal_message
    message = "Posting on this site is done by its ingest, not by hand: images reach the booru through the site's own bots, and accounts cannot upload, post or replace files directly."
    message += " (No posting account is configured at all: #{SETTING} is empty, so nobody may post.)" if names.empty?
    message
  end

  # Included by the policies of the doors that create content from a file or
  # a URL. `may_post?` is their rule; denial_message gives the refusal its
  # words.
  module Policy
    def may_post?
      PostingAccounts.may_post?(user)
    end

    def denial_message(query)
      return nil unless query.to_s.in?(%w[create? new?])
      return nil if may_post?

      PostingAccounts.refusal_message
    end
  end
end
