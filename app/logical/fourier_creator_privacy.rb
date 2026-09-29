# frozen_string_literal: true

# THE ONE RULE for data only a post's creator may see (operator ruling
# 2026-09-29: "creator decides who can see what, always. It's essentially the
# same data."). Two kinds of data, one rule, and this is the only place it is
# written:
#
#   private creator tags    FourierTagSource rows with public: false -- the
#                           prompt, normalised into tags
#   generation data         the FourierGenerationMetadata record, the post
#                           page's "Generation data" section, and generation
#                           keys in the ExifTool media_metadata
#                           (FourierGenerationFilter)
#
# Visible to the post's CREATOR. Not to an admin, not to a moderator, not to
# the posting bot that wrote it, and not to anyone a grant names. Nobody else,
# by any role or any row.
#
# WHO THE CREATOR IS, in order:
#
#   1. The Matrix account recorded for the post (FourierPostCreator), which the
#      posting bot filed at post creation from the authenticated event sender.
#      The viewer is that creator iff their request carries that MXID as its
#      VERIFIED identity (FourierIdentity: the proxy sets the header from the
#      fourier session and strips anything a client sent).
#   2. No recorded creator: the post's uploader, when the uploader is a person
#      -- the signed-in booru user whose id is post.uploader_id. A posting bot
#      (posting_bot_names, below) is never a creator.
#   3. Neither: NOBODY. A bot-uploaded post with no recorded creator shows its
#      private data to no one at all.
#
# NEVER from the post's tags. A 41chan_<localpart> tag is how the tunnel names
# a poster, but any member can edit a post's tags (PostPolicy#update? is
# unbanned? && visible?), so a member who adds 41chan_themselves to a post has
# added a tag and nothing else.
#
# NO SHARING, YET. The ruling's "unless set otherwise" is the CREATOR'S to
# set, and nothing lets a creator set anything: no creator-facing control
# exists. Until round three (2026-09-29) a view TagGrant on the creator's own
# poster tag stood in for one -- and a TagGrant is a moderator's row, not the
# creator's. Any moderator could grant one to themselves from the admin
# console and read the creator's prompts (round-two finding 2). So no
# TagGrant, of any ability, opens anything here (decision 2026-09-29;
# production held no tag_grants rows at all). The admin console no longer
# offers "view". When a creator-facing control exists, this is where it is
# read, and nowhere else.
module FourierCreatorPrivacy
  module_function

  # fourier-tunnel's poster.js SAFE: a localpart outside this is never minted
  # into a poster tag, so it has none.
  POSTER_TAG_LOCALPART = /\A[a-z0-9_-]+\z/

  # May `user`, on `request`, see `post`'s creator-only data?
  #
  # @param post [Post]
  # @param user [User, nil] the signed-in booru account (User.anonymous or nil
  #   when signed out)
  # @param request [ActionDispatch::Request, nil] carries the verified Matrix
  #   identity; nil outside a request, which can then match no MXID
  def visible_to?(post, user, request)
    return false if post&.id.nil?

    readable_post_ids([post], user, request).include?(post.id)
  end

  # The same rule for a page of posts, in one query for the recorded creators.
  # Returns the Set of post ids whose creator-only data this viewer may see.
  def readable_post_ids(posts, user, request)
    posts = Array(posts).compact.select(&:id)
    return Set.new if posts.empty?

    creators = FourierPostCreator.where(post_id: posts.map(&:id)).pluck(:post_id, :mxid).to_h
    viewer_id = signed_in_id(user)

    posts.each_with_object(Set.new) do |post, readable|
      mxid = creators[post.id]
      readable << post.id if mxid ? identity_matches?(request, mxid) : uploader?(post, user, viewer_id)
    end
  end

  # Rule 2: nothing recorded, and the signed-in viewer uploaded the post and
  # is a person.
  def uploader?(post, user, viewer_id)
    viewer_id.present? && post.uploader_id == viewer_id && !posting_bot?(user)
  end

  # Is `user` one of the accounts that post on others' behalf?
  def posting_bot?(user)
    return false if user.nil? || user.name.blank?

    posting_bot_names.any? { |name| name.casecmp?(user.name) }
  end

  # Danbooru.config.fourier_posting_bot_names, as a list of names. A
  # DANBOORU_FOURIER_POSTING_BOT_NAMES override arrives as one string; it is
  # split on spaces and commas rather than read as a single name.
  def posting_bot_names
    names = Danbooru.config.fourier_posting_bot_names
    names = names.split(/[\s,]+/) if names.is_a?(String)
    Array(names).map(&:to_s).compact_blank
  end

  # The MXID a poster tag names, or nil for a tag that is not one
  # (poster.js mxidForPosterTag). For the backfill only: a tag is a proposal
  # there, read by a person before anything is written, and never a creator.
  def mxid_for_poster_tag(tag)
    match = /\A#{Regexp.escape(CreatorActivity::TUNNEL_PREFIX)}(.+)\z/o.match(tag.to_s)
    return nil unless match && match[1].match?(POSTER_TAG_LOCALPART)

    "@#{match[1]}:#{Danbooru.config.fourier_matrix_server_name}"
  end

  # The request's verified identity is `mxid` (FourierIdentity.matches?).
  def identity_matches?(request, mxid)
    !request.nil? && FourierIdentity.matches?(request, mxid)
  end

  # The viewer's booru id, or nil for a signed-out viewer. User.anonymous has
  # no id; the guard is for anything else that says it is anonymous.
  def signed_in_id(user)
    return nil if user.nil? || (user.respond_to?(:is_anonymous?) && user.is_anonymous?)

    user.id
  end
end
