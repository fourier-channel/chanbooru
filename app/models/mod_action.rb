# frozen_string_literal: true

class ModAction < ApplicationRecord
  # Fork: rows name posts: its subject can be a post ("deleted post #N"). Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  MOD_ONLY_CATEGORIES = %i[
    ip_ban_create
    ip_ban_delete
    ip_ban_undelete
    moderation_report_handled
    moderation_report_rejected
    email_address_update
    backup_code_send
  ]

  # Fork: categories ADMINS alone may read. A hidden creator is hidden from
  # everyone below admin (CreatorPrefixes visible_to), moderators included, so
  # anything about one is too; the entry itself never names the tag either.
  # A creator claim keys that creator's control over who sees their posts and
  # is decided by an admin alone (CREATOR_VISIBILITY Q6, 2026-10-07);
  # moderators, who see nothing a creator hid (Q2), are not shown who was
  # given that control either, nor whose account a creator page is unlinked
  # from -- nor how a creator's panel is set: who is in their groups, who is
  # allowed or blocked, which posts are narrowed -- nor that an admin opened
  # one of those posts (Q2: every such view is logged, and it names the post).
  ADMIN_ONLY_CATEGORIES = %i[
    creator_visibility_update
    artist_claim_approve
    artist_claim_reject
    creator_gallery_unlink
    creator_audience_update
    creator_group_create
    creator_group_delete
    creator_group_member_add
    creator_group_member_remove
    creator_join_request_approve
    creator_join_request_reject
    creator_user_rule_update
    creator_hidden_post_view
    creator_group_update
  ].freeze

  dtext_attribute :description, inline: true # defines :dtext_description

  belongs_to :creator, class_name: "User"
  belongs_to :subject, polymorphic: true, optional: true

  # ####DIVISIONS#####
  # Groups:     0-999
  # Individual: 1000-1999
  # ####Actions#####
  # Create:   0
  # Update:   1
  # Delete:   2
  # Undelete: 3
  # Ban:      4
  # Unban:    5
  # Misc:     6-19
  enum :category, {
    user_delete: 2,
    user_undelete: 3,
    user_ban: 4,
    user_unban: 5,
    user_name_change: 6,
    user_level_change: 7,
    user_approval_privilege: 8,
    user_upload_privilege: 9,
    user_ban_update: 10,
    user_account_upgrade: 19, # XXX unused
    user_feedback_update: 21,
    user_feedback_delete: 22,
    post_delete: 42,
    post_undelete: 43,
    post_ban: 44,
    post_unban: 45,
    post_permanent_delete: 46,
    post_move_favorites: 47,
    post_regenerate: 48,
    post_regenerate_iqdb: 49,
    post_note_lock_create: 210,
    post_note_lock_delete: 212,
    post_rating_lock_create: 220,
    post_rating_lock_delete: 222,
    post_vote_delete: 232,
    post_vote_undelete: 233,
    pool_delete: 62,
    pool_undelete: 63,
    media_asset_delete: 72,
    media_asset_expunge: 76,
    artist_ban: 184,
    artist_unban: 185,
    comment_update: 81,
    comment_delete: 82,
    comment_vote_delete: 92,
    comment_vote_undelete: 93,
    forum_topic_delete: 202,
    forum_topic_undelete: 203,
    forum_topic_lock: 206,
    forum_post_update: 101,
    forum_post_delete: 102,
    moderation_report_handled: 306,
    moderation_report_rejected: 307,
    tag_alias_create: 120,
    tag_alias_update: 121, # XXX unused
    tag_alias_delete: 122,
    tag_implication_create: 140,
    tag_implication_update: 141, # XXX unused
    tag_implication_delete: 142,
    tag_deprecate: 240,
    tag_undeprecate: 242,
    ip_ban_create: 160,
    ip_ban_delete: 162,
    ip_ban_undelete: 163,
    news_update_create: 300,
    news_update_update: 301,
    news_update_delete: 302,
    news_update_undelete: 303,
    site_credential_create: 400,
    site_credential_delete: 402,
    site_credential_enable: 406,
    site_credential_disable: 407,
    email_address_update: 501,
    backup_code_send: 606,
    mass_update: 1000, # XXX unused
    # Fork: 1100+ are 41chan's own. creator_visibility_update -- a creator
    # released from, or returned to, their prefix's default (CreatorTagRelease).
    # chanbooru-53's creator-visibility categories take 1101 and up.
    creator_visibility_update: 1100,
    artist_claim_approve: 1101, # creator claims, ArtistClaim#approve!/#reject!
    artist_claim_reject: 1102,
    creator_gallery_unlink: 1103, # an admin clears a creator page's booru account (CreatorGalleriesController)
    # Who sees a creator's posts (CREATOR_VISIBILITY sections 4-5): the panel's
    # writes, by the creator or an admin. Admin-only above, with the claims.
    creator_audience_update: 1104, # a creator default or a per-post override (CreatorGallery, CreatorPostAudience)
    creator_group_create: 1105, # CreatorGroup.make!
    creator_group_delete: 1106, # CreatorGroup#dissolve!
    creator_group_member_add: 1107, # CreatorGroup#add_member! (by hand, by an approved request, or automation)
    creator_group_member_remove: 1108, # CreatorGroup#remove_member!
    creator_join_request_approve: 1109, # CreatorJoinRequest#approve!
    creator_join_request_reject: 1110, # CreatorJoinRequest#reject!
    creator_user_rule_update: 1111, # a per-user allow or block set or cleared (CreatorUserRule)
    creator_hidden_post_view: 1112, # an admin opened the page of a post its creator hid from them (PostsController#show, Q2)
    creator_group_update: 1113, # a group opened to, or closed to, join requests (CreatorGroup#open_to_requests!; the creator panel, 2026-10-09)
  }

  normalizes :category, with: ->(category) { category.to_s.parameterize.underscore.presence }

  def self.model_types
    %w[Artist Comment CommentVote ForumPost ForumTopic IpBan ModerationReport NewsUpdate Pool Post PostVote SiteCredential Tag TagAlias TagImplication User]
  end

  def self.visible(user)
    if user.is_admin?
      all
    elsif user.is_moderator?
      where.not(category: ADMIN_ONLY_CATEGORIES)
    else
      where.not(category: MOD_ONLY_CATEGORIES + ADMIN_ONLY_CATEGORIES)
    end
  end

  # Fork: a mod action whose subject is a post the viewer may not see is not
  # shown -- "deleted post #N, reason: troll jail: shock" names the post and
  # why it went. The ApplicationRecord rule keys on belongs_to :post; a mod
  # action names its post through the polymorphic subject instead.
  def self.without_hidden_posts(user)
    hidden = Post.hidden_from(user)
    return all if hidden.nil?

    # Correlated, for the reason ApplicationRecord.without_hidden_posts gives.
    where.not(hidden.where(Post.arel_table[:id].eq(arel_table[:subject_id])).where(arel_table[:subject_type].eq("Post")).arel.exists)
  end

  def hidden_by_post_from?(user)
    subject_type == "Post" && subject.present? && subject.hidden_from?(user)
  end

  def self.search(params, current_user)
    q = search_attributes(params, [:id, :created_at, :updated_at, :category, :description, :creator, :subject], current_user: current_user)

    case params[:order]
    when "created_at_asc"
      q = q.order(created_at: :asc, id: :asc)
    else
      q = q.apply_default_order(params)
    end

    q
  end

  def category_id
    self.class.categories[category]
  end

  def self.log(description, category, subject:, user:)
    create!(description: description, category: category, subject: subject, creator: user)
  end

  def self.available_includes
    [:creator]
  end
end
