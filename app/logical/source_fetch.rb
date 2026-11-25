# frozen_string_literal: true

# WHO MAY MAKE THIS SITE FETCH AN ADDRESS: the posting bots, and nobody else.
#
# A source extractor (Source::Extractor) sends HTTP requests to an address its
# caller chose. The only use this site has for that is downloading the images
# its posting bots upload (PostingAccounts), so that is the only thing it is
# allowed for (2026-11-25).
#
# Asked in one place, the HTTP client every extractor sends its requests with
# (Source::Extractor#external_http, through Danbooru::Http::RequestedBy), so a
# door added later is refused without naming it here. The refusal is raised
# before the name is looked up, and it is a User::PrivilegeError, so whichever
# page asked answers 403 with the message.
#
# The requester is the account in `on_behalf_of`, or else the current user. A
# background job runs as the system user, which is not a posting bot: a job
# that fetches says who for.
class SourceFetch < ActiveSupport::CurrentAttributes
  class RefusedError < User::PrivilegeError; end

  attribute :on_behalf_of_user

  # Fetch what is fetched in the block for `user`.
  def self.on_behalf_of(user, &)
    set(on_behalf_of_user: user, &)
  end

  # The account a fetch started now is for.
  def self.requester
    on_behalf_of_user || CurrentUser.user
  end

  def self.allowed?(user = requester)
    PostingAccounts.may_post?(user)
  end

  # @raise [RefusedError] if the site may not fetch an address for `user`
  def self.refuse!(user)
    raise RefusedError, refusal_message unless allowed?(user)
  end

  # What a refused caller is told.
  def self.refusal_message
    message = "This site does not fetch web addresses for visitors or members. To find similar images, upload the file itself or give a post ID at /iqdb_queries; to find an artist, search by name at /artists."
    message += " Only the site's posting accounts (#{PostingAccounts::SETTING}) may have an address fetched."
    message += " (No posting account is configured at all: #{PostingAccounts::SETTING} is empty.)" if PostingAccounts.names.empty?
    message
  end
end
