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
    user_password_reset # Fork: see the category below
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
    tag_flag
    tag_flag_release
    tag_banish
    tag_unbanish
  ].freeze

  # The flagged-tag review queue's decisions (TagQuarantine), and the jail
  # panel's unbanish. A row about a tag that is banished NOW is shown to
  # nobody but the pipeline -- an admin never sees a banished name, not even
  # in an old flag or unbanish row (see .visible); once unbanished, they show.
  TAG_QUARANTINE_CATEGORIES = %i[tag_flag tag_flag_release tag_banish tag_unbanish].freeze

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
    # A jailing the booru made itself -- the banished-tag failsafe or the post
    # page pill's jail-on -- written by the system user (Post#jail_by_booru!).
    # The jail panel reads these through GET /fourier_jail/release.json
    # (operator 2026-10-09: "The booru should obviously communicate back to
    # the panel that is controlling the visibility of posts on the booru.").
    post_jail: 1114,
    # The jail panel's release ending a reported jailing that sat on another
    # account's deletion: the tag lifted, that deletion left standing
    # (FourierJailController#decide!). Ends Post#jailing_stands?, so the
    # ordinary undelete door opens again (review of the 2026-10-10 build).
    post_unjail: 1115,
    # Original-character claims (CharacterClaim, OC ownership 2026-10-11),
    # subject the Tag. Readable by everyone a mod log is: an OC claim hides
    # nothing, and its result is shown on posts. Named by slug, never by
    # matrix_id. character_claim_reject also records an admin withdrawing an
    # approval. character_claim_hold records ownership a tag move assigned to
    # a creator with no gallery yet (CharacterClaim::HELD), by the approver of
    # the move; its approval is logged as character_claim_approve, by that same
    # approver, the moment the gallery is made.
    character_claim_approve: 1116,
    character_claim_reject: 1117,
    character_claim_release: 1118,
    character_claim_hold: 1119,
    # The flagged-tag review queue (TagQuarantine, operator rulings
    # 2026-10-12), subject the Tag, admins only: a flag, a release back to
    # normal, and a banish -- whose row never names the tag.
    tag_flag: 1120,
    tag_flag_release: 1121,
    tag_banish: 1122,
    tag_unbanish: 1123,
    # A booru password reset from the server's command line, written by the
    # system user (PasswordReveal, operator rulings 2026-10-19). Moderators
    # and up, as an admin's change of someone's email is: it says an account
    # was taken over or locked out. Never carries the password.
    user_password_reset: 1124,
  }

  normalizes :category, with: ->(category) { category.to_s.parameterize.underscore.presence }

  def self.model_types
    %w[Artist Comment CommentVote ForumPost ForumTopic IpBan ModerationReport NewsUpdate Pool Post PostVote SiteCredential Tag TagAlias TagImplication User]
  end

  def self.visible(user)
    if TagBanishment.pipeline?(user)
      user.is_admin? ? all : where.not(category: MOD_ONLY_CATEGORIES + ADMIN_ONLY_CATEGORIES)
    elsif user.is_admin?
      ids = TAG_QUARANTINE_CATEGORIES.map { |category| categories.fetch(category.to_s) }
      where.not(sanitize_sql_array([<<~SQL.squish, { categories: ids }]))
        mod_actions.category IN (:categories) AND mod_actions.subject_type = 'Tag'
        AND mod_actions.subject_id IN (SELECT tag_id FROM tag_quarantines WHERE state = 'banished')
      SQL
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
  #
  # And one whose subject is a tag, alias, implication or artist entry
  # (an artist claim's decision) naming a tag the
  # viewer may not be shown (TagQuarantine: flagged below admin, banished to
  # all but the pipeline) -- "deprecated tag [[secret_(thing)]]" names it as
  # plainly as the tag index would.
  def self.without_hidden_posts(user)
    relation = all
    hidden = Post.hidden_from(user)
    # Correlated, for the reason ApplicationRecord.without_hidden_posts gives.
    relation = relation.where.not(hidden.where(Post.arel_table[:id].eq(arel_table[:subject_id])).where(arel_table[:subject_type].eq("Post")).arel.exists) unless hidden.nil?

    names = TagQuarantine.hidden_names_for(user)
    return relation if names.empty?

    relation.where.not(sanitize_sql_array([<<~SQL.squish, { names: names }]))
      (COALESCE(mod_actions.subject_type, '') = 'Tag' AND COALESCE(mod_actions.subject_id, 0) IN (SELECT id FROM tags WHERE name IN (:names)))
      OR (COALESCE(mod_actions.subject_type, '') = 'TagAlias' AND COALESCE(mod_actions.subject_id, 0) IN (SELECT id FROM tag_aliases WHERE antecedent_name IN (:names) OR consequent_name IN (:names)))
      OR (COALESCE(mod_actions.subject_type, '') = 'TagImplication' AND COALESCE(mod_actions.subject_id, 0) IN (SELECT id FROM tag_implications WHERE antecedent_name IN (:names) OR consequent_name IN (:names)))
      OR (COALESCE(mod_actions.subject_type, '') = 'Artist' AND COALESCE(mod_actions.subject_id, 0) IN (SELECT id FROM artists WHERE name IN (:names)))
    SQL
  end

  def hidden_by_post_from?(user)
    case subject_type
    when "Post" then subject.present? && subject.hidden_from?(user)
    when "Tag", "TagAlias", "TagImplication", "Artist" then subject.present? && subject.hidden_by_post_from?(user)
    else false
    end
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
