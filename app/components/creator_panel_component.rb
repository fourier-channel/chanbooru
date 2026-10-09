# frozen_string_literal: true

# THE CREATOR'S PANEL: who sees a creator's posts, at the top of their page's
# edit screen (design CREATOR_VISIBILITY sections 4-7 and Q3-Q9; built
# 2026-10-09). The claim is the key to it (section 1), so it comes first:
# the requests waiting, the default, the groups, the people let in or kept
# out by name, and the posts set differently. Every write is a plain form to
# PATCH creators/:slug with panel=<act> (no new routes, 2026-09-24);
# CreatorGalleriesController decides who may, and the models log each one.
#
# Plain forms and <details> only: no script, no animation, nothing opens or
# moves but by the reader's own click (no element pushes others out of
# place) -- except the one group the last write was on, which the page
# after it draws open (open_group, by URL: remembered for one page, never
# stored). Every read goes through this gallery, in a fixed number of
# queries whatever the number of members, rules or overrides, and every
# list stops at MEMBER_LIMIT saying how many it does not show and how to
# reach them (fail loudly, 2026-09-13). The name box filters every list of
# people at once.
#
# Every field has a label and every repeated button names its row, so a
# screen reader hears "Remove bob from 41chan_saber_tier_1", not "Remove".
#
# What it says plainly, because the rulings asked for it: a block stops the
# signed-in account, not a signed-out look at a public post (section 6, Q8);
# groups never open a private post (Q9); tiers nest (Q3); an unreleased
# creator under a held-back prefix stays at the prefix's default whatever
# this panel says (section 7), with the release offered where it may be.
class CreatorPanelComponent < ApplicationComponent
  MEMBER_LIMIT = 200
  DECIDED_LIMIT = 50
  POSTS_PER_PAGE = 50

  attr_reader :gallery, :viewer, :refusal, :member_q, :page, :panel_post_id, :open_group

  # @param refusal [String, nil] why this viewer may not use the panel (the
  #   controller's panel_refusal), nil when they may
  # @param place [Hash] where the creator is in the panel, from the URL:
  #   post_id (the one-post editor), audience_page, member_q (the name box)
  #   and open_group (the group the last write was on)
  def initialize(gallery:, viewer:, refusal:, place: {})
    super
    @gallery = gallery
    @viewer = viewer
    @refusal = refusal
    @panel_post_id = place[:post_id].presence&.to_s&.delete_prefix("#")
    @page = [place[:audience_page].to_i, 1].max
    @member_q = place[:member_q].to_s.strip
    @open_group = place[:open_group].to_i
  end

  def path = helpers.creator_gallery_path(gallery)

  def admin_acting? = viewer.is_admin? && gallery.user_id != viewer.id

  def creator_name = gallery.title.presence || gallery.slug

  # The headings speak to the creator; to an admin acting on someone else's
  # page they name whose posts these are.
  def whose = admin_acting? ? "#{creator_name}'s" : "your"

  # --- groups -----------------------------------------------------------

  def groups
    @groups ||= gallery.creator_groups.order(Arel.sql("tier ASC NULLS LAST"), :name).to_a
  end

  def group_labels(ids)
    groups.select { |g| ids.include?(g.id) }.map(&:label)
  end

  def group_choices = groups.map { |g| [g.id, g.label] }

  def open?(group) = member_q.present? || open_group == group.id

  # Q3: a tier group's posts are seen by every higher tier too, so
  # dissolving it takes them from those members as well.
  def higher_tier_members(group)
    return 0 if group.tier.nil?

    groups.select { |g| g.tier && g.tier > group.tier }.sum { |g| member_counts.fetch(g.id, [0, 0]).first }
  end

  # group id => [active, ended], in one query.
  def member_counts
    @member_counts ||= CreatorGroupMembership.where(creator_group_id: groups.map(&:id)).group(:creator_group_id).pluck(
      :creator_group_id,
      Arel.sql(CreatorGroupMembership.sanitize_sql_array(["count(*) FILTER (WHERE expires_at IS NULL OR expires_at > ?)", now])),
      Arel.sql(CreatorGroupMembership.sanitize_sql_array(["count(*) FILTER (WHERE expires_at <= ?)", now])),
    ).to_h { |id, active, ended| [id, [active, ended]] }
  end

  # group id => [CreatorGroupMembership], at most MEMBER_LIMIT a group, by
  # name, filtered by the name box -- one query for every group.
  def members
    @members ||= capped_memberships(CreatorGroupMembership.active(now))
  end

  def ended_members
    @ended_members ||= capped_memberships(CreatorGroupMembership.where(expires_at: ..now))
  end

  # group id => [in the default?, posts listing it]
  def audience_uses
    @audience_uses ||= CreatorAudienceGroup.where(creator_group_id: groups.map(&:id)).group(:creator_group_id)
                                           .pluck(:creator_group_id, Arel.sql("bool_or(post_id IS NULL)"), Arel.sql("count(post_id)"))
                                           .to_h { |id, default, posts| [id, [default, posts]] }
  end

  def uses_words(group)
    default, posts = audience_uses.fetch(group.id, [false, 0])
    words = []
    words << "your default" if default
    words << "#{posts} #{"post".pluralize(posts)}" if posts > 0
    words.empty? ? "not used yet" : "used by: #{words.join(", ")}"
  end

  def how_joined(membership)
    case membership.source
    when CreatorGroupMembership::REQUEST then "asked and was let in"
    when CreatorGroupMembership::AUTOMATION then "added automatically"
    else "added by hand"
    end
  end

  # Of the people drawn as asking or as members, those a creator-wide block
  # keeps out -- never every block the gallery holds.
  def kept_out_ids
    @kept_out_ids ||= begin
      shown = pending_requests.map(&:user_id) + members.values.flatten.map(&:user_id)
      CreatorUserRule.where(creator_gallery: gallery, post_id: nil, rule: CreatorUserRule::BLOCK, user_id: shown.uniq).pluck(:user_id).to_set
    end
  end

  def master_tag = CreatorControl.master_tags(gallery.matrix_id).first

  def next_tier = (groups.filter_map(&:tier).max || 0) + 1

  # --- requests ---------------------------------------------------------

  def requests = CreatorJoinRequest.where(creator_group_id: gallery.creator_groups.select(:id))

  def pending_requests
    @pending_requests ||= requests.pending.includes(:user, :creator_group).order(:created_at, :id).limit(MEMBER_LIMIT).to_a
  end

  def pending_count
    @pending_count ||= requests.pending.count
  end

  def decided_requests
    @decided_requests ||= requests.where.not(status: CreatorJoinRequest::PENDING).includes(:user, :creator_group, :decided_by)
                                  .order(decided_at: :desc, id: :desc).limit(DECIDED_LIMIT).to_a
  end

  # --- the default --------------------------------------------------------

  def default_group_ids
    @default_group_ids ||= CreatorAudienceGroup.current_ids(gallery, nil)
  end

  def default_words = audience_words(gallery.default_audience, group_labels(default_group_ids))

  delegate :audience_words, to: :CreatorGallery

  # --- people let in or kept out ------------------------------------------

  # By name, in the database, at most MEMBER_LIMIT, filtered by the name box.
  def creator_wide_rules
    @creator_wide_rules ||= named(CreatorUserRule.where(creator_gallery: gallery, post_id: nil))
                            .includes(:user).order(Arel.sql("lower(users.name)"), :id).limit(MEMBER_LIMIT).to_a
  end

  def creator_wide_rule_count
    @creator_wide_rule_count ||= named(CreatorUserRule.where(creator_gallery: gallery, post_id: nil)).count
  end

  # The per-post rules on posts this gallery still controls; the others are
  # counted (stale_rule_count), never listed.
  def post_rules
    @post_rules ||= named(still_mine(CreatorUserRule.where(creator_gallery_id: gallery.id).where.not(post_id: nil)))
                    .includes(:user).order(:post_id, :id).limit(MEMBER_LIMIT).to_a
  end

  def post_rule_count
    @post_rule_count ||= named(still_mine(CreatorUserRule.where(creator_gallery_id: gallery.id).where.not(post_id: nil))).count
  end

  def stale_rule_count
    scope = CreatorUserRule.where(creator_gallery_id: gallery.id).where.not(post_id: nil)
    scope.count - still_mine(scope).count
  end

  # --- posts set differently ------------------------------------------------

  def overrides_scope = CreatorPostAudience.where(creator_gallery_id: gallery.id).where.not(audience: "inherit")

  def overrides
    @overrides ||= still_mine(overrides_scope).includes(post: :media_asset).order(updated_at: :desc, id: :desc)
                                              .offset((page - 1) * POSTS_PER_PAGE).limit(POSTS_PER_PAGE).to_a
  end

  def override_count
    @override_count ||= still_mine(overrides_scope).count
  end

  def stale_override_count = overrides_scope.count - override_count

  def last_page = [(override_count.to_f / POSTS_PER_PAGE).ceil, 1].max

  # [post id] => [group id], for the overrides on this page.
  def override_groups
    @override_groups ||= CreatorAudienceGroup.where(post_id: overrides.map(&:post_id), creator_group_id: groups.map(&:id))
                                             .pluck(:post_id, :creator_group_id).group_by(&:first).transform_values { |rows| rows.map(&:second) }
  end

  def thumb(post)
    (post.visible?(viewer) && !post.hidden_from?(viewer)) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  # --- the one-post editor ------------------------------------------------

  def editor_post
    return @editor_post if defined?(@editor_post)

    post = panel_post_id && Post.find_by(id: panel_post_id.to_i)
    @controllers = post ? CreatorControl.controller_gallery_ids([post]).fetch(post.id) : []
    @editor_post = @controllers.include?(gallery.id) ? post : nil
  end

  def not_your_post_words
    format(CreatorGalleriesController::NOT_YOUR_POST, panel_post_id.to_i)
  end

  def shared_post? = editor_post && @controllers.size > 1

  def editor_audience
    CreatorPostAudience.find_by(post: editor_post, creator_gallery: gallery)&.audience || "inherit"
  end

  def editor_group_ids = CreatorAudienceGroup.current_ids(gallery, editor_post)

  def editor_rules = CreatorUserRule.where(creator_gallery: gallery, post: editor_post).includes(:user).order(:id)

  # --- section 7: the release precondition ----------------------------------

  # [[tag, entry]] for this creator's own tags held back by their prefix and
  # not released; raises CreatorPrefixes::ConfigError when the list cannot
  # be read (the template says so).
  def held_back
    @held_back ||= begin
      own = CreatorControl.controlling_tags([[gallery.id, gallery.matrix_id]]).fetch(gallery.id, [])
      released = CreatorTagRelease.released_names
      entries = CreatorPrefixes.visibility_config[:entries].reject { |e| e.visible_to == "everyone" }
      own.filter_map do |tag|
        entry = entries.find { |e| tag.start_with?(e.prefix) && tag.length > e.prefix.length }
        [tag, entry] if entry && released.exclude?(tag)
      end
    end
  end

  def visible_to_words(entry)
    case entry.visible_to
    when "admins" then "admins"
    when "members" then "signed-in members"
    else entry.visible_to
    end
  end

  def may_release?(tag) = CreatorTagRelease.may_set?(viewer, tag)

  private

  def now = @now ||= Time.zone.now

  # A creator's per-post rows (rules, overrides) on posts this gallery still
  # controls, in SQL: CreatorControl.controlled_pairs_sql keeps the candidate
  # pairs the gallery controls without listing every post of the gallery.
  def still_mine(scope)
    candidates = scope.select("post_id, creator_gallery_id AS gallery_id").to_sql
    controlled = CreatorControl.controlled_pairs_sql([[gallery.id, gallery.matrix_id]], only: candidates)
    scope.where("#{scope.table_name}.post_id IN (SELECT c.post_id FROM (#{controlled}) c)")
  end

  # `scope` joined to its users, and filtered by the name box when it is used.
  def named(scope)
    scope = scope.joins(:user)
    member_q.present? ? scope.where("users.name ILIKE ?", "%#{User.sanitize_sql_like(member_q)}%") : scope
  end

  def capped_memberships(scope)
    filtered = named(scope.where(creator_group_id: groups.map(&:id)))
    ranked = filtered.select("creator_group_memberships.*, row_number() OVER (PARTITION BY creator_group_memberships.creator_group_id ORDER BY lower(users.name)) AS rank")
    CreatorGroupMembership.from(ranked, :creator_group_memberships).where(rank: ..MEMBER_LIMIT)
                          .includes(:user, :added_by).order(:rank).group_by(&:creator_group_id)
  end
end
