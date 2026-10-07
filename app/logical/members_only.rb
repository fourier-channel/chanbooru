# frozen_string_literal: true

# MEMBERS ONLY: the one refusal a signed-out visitor gets from a page that is
# for members, and the rule that every listing naming posts is such a page.
#
# THE REFUSAL is the 404 a hidden post gets (ActiveRecord::RecordNotFound,
# rendered by ApplicationController as "That record was not found."), the
# same answer the retired sections give: a 403 or a redirect to /login would
# confirm there is something there. It was first written inline for
# /creator_prefixes (operator, 2026-10-07); it lives here so a second
# members-only page is the same page, not a second rule.
#
# THE LISTING RULE (operator, 2026-10-07): "An anonymous viewer is not
# supposed to be paging through all of the content 20 posts at a time." The
# browsing cap (PostSets::Post#enforce_browsing_cap!) held /posts to one page,
# but nothing else asked it. Measured on production that day as a signed-out
# visitor: /explore/posts/popular answered every page, every date and any
# `limit=` (walking ?date= backwards enumerates the whole booru at page 1);
# /artist_commentaries?page=2 answered 40 posts with previews and their source
# lines; /post_approvals?page=2 22 posts with previews; /favorites,
# /post_events, /post_votes, /post_appeals, /post_flags, /post_replacements,
# /favorite_groups and /uploads all answered 200.
#
# Where it is asked, so a listing added later gets it without knowing:
#
# - ApplicationRecord.paginated_search, the one place every index door
#   passes, for every model whose rows name posts (`names_posts?`: any model
#   that belongs_to :post, plus the ones that name posts another way and say
#   so by overriding it). The same family without_hidden_posts covers.
# - The few doors that list posts without paginated_search, by hand:
#   /explore/posts/popular, /pools/gallery, a pool's and a favorite group's
#   page of posts, /comments grouped by post, /iqdb_queries,
#   /recommended_posts and /moderator/dashboard.
#
# A post's own page, /posts and the landing page are not listings in this
# sense and are untouched: /posts keeps its browsing cap, and a post's page
# answers by Post#hidden_from?. A signed-in member at ANY level sees exactly
# what they saw before.
module MembersOnly
  module_function

  # Signed in, at any level. The anonymous user is the only non-member.
  def member?(user)
    user.present? && !user.is_anonymous?
  end

  # Refuse a non-member with the hidden-post 404.
  def require!(user)
    raise ActiveRecord::RecordNotFound unless member?(user)
  end

  # Is this user shown listings that name posts? See the config switch for
  # why it is off under test.
  def sees_post_listings?(user)
    !Danbooru.config.post_listings_members_only? || member?(user)
  end

  # The listing rule: refuse a non-member a listing that names posts.
  def post_listing!(user)
    raise ActiveRecord::RecordNotFound unless sees_post_listings?(user)
  end
end
