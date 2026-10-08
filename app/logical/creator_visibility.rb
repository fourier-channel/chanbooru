# frozen_string_literal: true

# WHAT A CREATOR'S PANEL SAYS ABOUT ONE VIEWER AND ONE POST -- the single
# answer, and the only place it is written (design CREATOR_VISIBILITY
# sections 4, 5, 7 and 9, ruled 2026-10-07: a claim "allows the user access to
# a control panel that lets them set the visibility of their posts both on a
# general, per 'group' and per-user case").
#
# One of three answers:
#
#   :hidden   the creator narrowed the post away from this viewer -- for
#             enforcement, exactly what gate 1 means for a signed-out visitor
#             (section 6): out of results, counts, neighbours and media.
#   :allowed  the creator explicitly let this viewer in (a group, a named
#             user, or being the controller) -- the input to WIDEN past the
#             site's level gate (Q1: "a creator can widen").
#   :default  no creator opinion beyond public: the site's own rules decide.
#
# PURE. `snapshot` reads every row a batch needs in a fixed number of queries;
# `verdict` decides from that snapshot alone. Nothing here enforces: Post,
# PostQuery, the policies and the doors read this module in a later stage.
#
# THE ORDER (section 9, "Precedence"):
#
#   1. Nobody controls the post (CreatorControl) -> :default.
#   2. Who always sees (section 9): admins (Q2; enforcement logs their views)
#      and the posting bots, the prefix list's editors, so a re-upload is
#      never refused -> :default, never hidden, whatever any rule says. The
#      controller -> :allowed (their own post, past the level gate, as an
#      uploader sees their own today).
#   3. Each controlling gallery's own answer, then NARROWEST WINS between
#      them (section 9, two claimants): :hidden if any hides, :allowed only
#      if every one allows, otherwise :default. Per gallery:
#        a. a BLOCK on this viewer, creator-wide or on this post -> :hidden.
#           "A block beats every allow" (section 4, Q8);
#        b. the AUDIENCE: that gallery's own override on the post unless it
#           says inherit (Q4: the override beats the default), otherwise the
#           creator default (unset decides as public). An override replaces
#           the default's audience and its groups, nothing else: the named
#           users are a level of their own (section 4);
#        c. NARROWEST WINS between the levels (section 4): private is "the
#           creator alone" -> :hidden, whatever group or name says otherwise;
#           groups -> :allowed for a member of a listed group, else :hidden;
#           public -> :allowed for a member of a listed group or a named
#           user (creator-wide or on this post), else :default. Tiered groups
#           NEST within one creator (Q3: tier_2 sees everything tier_1 sees);
#           an untiered group admits its members only; an expired membership
#           is no membership.
#        d. THE RELEASE (section 7): while one of this creator's OWN creator
#           tags on the post sits under a prefix the site holds back
#           (CreatorPrefixes visible_to other than everyone) unreleased
#           (CreatorTagRelease), "nothing in the panel widens it": :allowed
#           becomes :default. Its narrowing stands -- "a creator's
#           restriction (private, groups-only, a block) always narrows" --
#           and the prefix rule narrows on its own besides. Another creator's
#           held-back tag on the post is that prefix rule's business, not
#           this creator's panel's.
#   4. WHAT WIDENING NEVER REACHES (section 7): :allowed becomes :default for
#      a signed-out viewer (every allow names an account), a banned viewer
#      (user.is_banned?; banblocked? is about the post), and any post carrying
#      TagBanishment.post_tags (jail: "never shown, to anyone"). A narrowing
#      still stands for them.
#
# "public" on its own widens nothing: it means whoever the site already lets
# see the post. Only a named group or user widens.
#
# READINGS AWAITING A RULING (stated so they can be corrected; section 4
# marks its precedence [EXTRAPOLATION]): a named allow does not open a
# private or groups-only post -- narrowest wins, and private is "the creator
# alone" -- so naming a user widens only under public; and an unreleased
# creator's narrowing still hides, reading section 7's "nothing in the panel
# widens it" with its "a creator's restriction always narrows". Both fail
# closed: a wrong reading hides too much, never shows too much.
#
# Two shapes, which must always agree (creator_visibility_test asks every case
# through each): per post (`decide`, `decisions`) and per viewer over the
# whole site (`hidden_post_ids_for`), both in a fixed number of queries per
# batch -- no N+1.
module CreatorVisibility
  HIDDEN = :hidden
  ALLOWED = :allowed
  DEFAULT = :default

  BATCH_SIZE = 1000

  # Everything one batch is decided from. `verdict` reads nothing else.
  Snapshot = Struct.new(
    :controllers,    # post id => [controlling gallery id]
    :owner,          # gallery id => linked booru user id (nil when unlinked)
    :audience,       # gallery id => creator default (nil until chosen)
    :overrides,      # [post id, gallery id] => that gallery's override
    :default_groups, # gallery id => [group id in the creator default]
    :post_groups,    # [post id, gallery id] => [group id in that override]
    :groups,         # group id => [gallery id, tier or nil]
    :member_of,      # Set of group ids the viewer is an active member of
    :top_tier,       # gallery id => the highest tier the viewer holds there
    :rules,          # [gallery id, post id or nil] => "allow" | "block"
    :held_back,      # prefixes the site does not show to everyone
    :own_tags,       # gallery id => the creator tags that are its own
    :released,       # Set of released creator tag names
    :jail,           # tag names that jail a post
    keyword_init: true,
  )

  module_function

  # @return [Symbol] :hidden, :allowed or :default -- :default for a post not
  #   yet saved, which nobody controls (as CreatorControl.controls? answers)
  def decide(post, viewer) = decisions([post], viewer).fetch(post.id, DEFAULT)

  # @param posts [Enumerable<Post>] each needs id and tag_string
  # @return [Hash{Integer => Symbol}] post id => decision, every saved post
  #   present
  def decisions(posts, viewer, now: Time.zone.now)
    posts = Array(posts).select(&:id)
    return {} if posts.empty?
    return posts.to_h { |post| [post.id, DEFAULT] } if sees_everything?(viewer)

    controllers = CreatorControl.controller_gallery_ids(posts)
    return posts.to_h { |post| [post.id, DEFAULT] } if controllers.values.all?(&:empty?)

    snap = snapshot(posts, controllers, viewer, now)
    posts.to_h { |post| [post.id, verdict(post, viewer, snap)] }
  end

  # The posts among `posts` hidden from `viewer`.
  #
  # @return [Array<Integer>] sorted post ids
  def hidden_post_ids(posts, viewer)
    decisions(posts, viewer).select { |_, decision| decision == HIDDEN }.keys.sort
  end

  # Every post on the site hidden from `viewer` -- the id list query-level
  # enforcement wants, as CreatorPrefixes.hidden_post_ids_for gives. Decided
  # by `decisions` over every post that COULD be hidden, in batches.
  #
  # @return [Array<Integer>] sorted post ids
  def hidden_post_ids_for(viewer)
    return [] if sees_everything?(viewer)

    candidate_post_ids(viewer).each_slice(BATCH_SIZE).flat_map do |ids|
      hidden_post_ids(Post.where(id: ids).select(:id, :tag_string).to_a, viewer)
    end.sort
  end

  # --- internals ---

  def signed_in?(viewer) = viewer.present? && !viewer.is_anonymous?

  # Admins and the posting bots. The editors are read through the visibility
  # copy of the list, which keeps the last good one when the file breaks.
  def sees_everything?(viewer)
    signed_in?(viewer) && (viewer.is_admin? || CreatorPrefixes.visibility_config[:editors].include?(viewer.name))
  end

  # A superset of the posts hidden from `viewer`: only a block, an override
  # to groups or private, or a creator default of groups or private can hide.
  def candidate_post_ids(viewer)
    blocks = signed_in?(viewer) ? CreatorUserRule.where(user_id: viewer.id, rule: CreatorUserRule::BLOCK).pluck(:creator_gallery_id, :post_id) : []
    narrowed = CreatorPostAudience.where(audience: %w[groups private]).pluck(:post_id)
    wide_blocks = blocks.filter_map { |gallery, post| gallery if post.nil? }
    galleries = CreatorGallery.where(default_audience: %w[groups private]).or(CreatorGallery.where(id: wide_blocks)).pluck(:id, :matrix_id)

    (narrowed + blocks.filter_map(&:second) + CreatorControl.gallery_post_ids(galleries)).uniq
  end

  def snapshot(posts, controllers, viewer, now)
    post_ids = posts.map(&:id)
    gallery_ids = controllers.values.flatten.uniq
    galleries = CreatorGallery.where(id: gallery_ids).pluck(:id, :user_id, :default_audience, :matrix_id)
    groups = CreatorGroup.where(creator_gallery_id: gallery_ids).pluck(:id, :creator_gallery_id, :tier).to_h { |id, *rest| [id, rest] }
    listed = CreatorAudienceGroup.where(creator_group_id: groups.keys, post_id: [nil, *post_ids]).pluck(:creator_group_id, :post_id)
    member_of = signed_in?(viewer) ? CreatorGroupMembership.active(now).where(user_id: viewer.id, creator_group_id: groups.keys).pluck(:creator_group_id).to_set : Set.new
    rules = signed_in?(viewer) ? CreatorUserRule.where(user_id: viewer.id, creator_gallery_id: gallery_ids, post_id: [nil, *post_ids]).pluck(:creator_gallery_id, :post_id, :rule) : []
    overrides = CreatorPostAudience.where(post_id: post_ids, creator_gallery_id: gallery_ids).pluck(:post_id, :creator_gallery_id, :audience)
    defaults, per_post = listed.partition { |_, post| post.nil? }
    held_back = CreatorPrefixes.visibility_config[:entries].reject { |e| e.visible_to == "everyone" }.map(&:prefix)

    Snapshot.new(
      controllers: controllers,
      owner: galleries.to_h { |id, user_id, *| [id, user_id] },
      audience: galleries.to_h { |id, _, audience, _| [id, audience] },
      overrides: overrides.to_h { |post, gallery, audience| [[post, gallery], audience] },
      default_groups: defaults.group_by { |group, _| groups[group].first }.transform_values { |rows| rows.map(&:first) },
      post_groups: per_post.group_by { |group, post| [post, groups[group].first] }.transform_values { |rows| rows.map(&:first) },
      groups: groups,
      member_of: member_of,
      top_tier: member_of.filter_map { |id| groups[id] if groups[id].last }.group_by(&:first).transform_values { |rows| rows.map(&:last).max },
      rules: rules.to_h { |gallery, post, rule| [[gallery, post], rule] },
      held_back: held_back,
      own_tags: held_back.any? ? CreatorControl.controlling_tags(galleries.map { |id, _, _, mxid| [id, mxid] }) : {},
      released: held_back.any? ? CreatorTagRelease.released_names : Set.new,
      jail: TagBanishment.post_tags,
    )
  end

  # The decision for one post, from the snapshot alone (the order above).
  def verdict(post, viewer, snap)
    galleries = snap.controllers.fetch(post.id, [])
    return DEFAULT if galleries.empty?

    tags = post.tag_array
    owned = signed_in?(viewer) ? galleries.select { |gallery| snap.owner[gallery] == viewer.id } : []
    if owned.any?
      decision = (owned.any? { |gallery| released?(tags, gallery, snap) }) ? ALLOWED : DEFAULT
    else
      decision = narrowest(galleries.map { |gallery| gallery_verdict(post, tags, gallery, snap) })
    end
    return DEFAULT if decision == ALLOWED && !widenable?(tags, viewer, snap)

    decision
  end

  def narrowest(verdicts)
    return HIDDEN if verdicts.include?(HIDDEN)

    verdicts.all?(ALLOWED) ? ALLOWED : DEFAULT
  end

  def gallery_verdict(post, tags, gallery, snap)
    rules = [snap.rules[[gallery, nil]], snap.rules[[gallery, post.id]]]
    return HIDDEN if rules.include?(CreatorUserRule::BLOCK)

    override = snap.overrides[[post.id, gallery]]
    if override.present? && override != "inherit"
      audience = override
      groups = snap.post_groups.fetch([post.id, gallery], [])
    else
      audience = snap.audience[gallery] || "public"
      groups = snap.default_groups.fetch(gallery, [])
    end
    member = groups.any? { |group| member?(group, snap) }

    # Narrowest wins: private admits nobody, groups only its members; under
    # public a member or a named user is let in.
    return HIDDEN if audience == "private" || (audience == "groups" && !member)
    return DEFAULT unless member || rules.include?(CreatorUserRule::ALLOW)

    released?(tags, gallery, snap) ? ALLOWED : DEFAULT
  end

  def member?(group, snap)
    gallery, tier = snap.groups.fetch(group)
    tier ? snap.top_tier.fetch(gallery, 0) >= tier : snap.member_of.include?(group)
  end

  # Does none of this creator's own tags on the post sit under a held-back
  # prefix unreleased?
  def released?(tags, gallery, snap)
    (tags & snap.own_tags.fetch(gallery, [])).none? do |tag|
      snap.released.exclude?(tag) && snap.held_back.any? { |prefix| tag.start_with?(prefix) && tag.length > prefix.length }
    end
  end

  def widenable?(tags, viewer, snap)
    signed_in?(viewer) && !viewer.is_banned? && !tags.intersect?(snap.jail)
  end
end
