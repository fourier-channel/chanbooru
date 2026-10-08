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
# `verdict` decides from that snapshot alone. Nothing here enforces.
#
# ENFORCEMENT (stage 3, 2026-10-08) reads per-viewer sets, each computed ONCE
# per request and then answered from memory (`memoized`; the memo is a
# CurrentAttributes, which Rails resets around every request and job). The
# doors ask per post -- a page of thumbnails, each nested post in an API
# answer -- so a per-post decision would be a dozen queries a thumbnail. The
# hidden set is decided per gallery (`hidden_post_ids_for`), the widened one
# over the gated posts of the galleries a viewer is related to; neither
# decides the site's posts one by one:
#   - NARROW: Post#hidden_by_creator? (inside #hidden_from? and
#     Post.hidden_from, so every record that names a post) and PostQuery's
#     implicit `-id:` term, from `hidden_ids` -- results, counts, neighbours,
#     the page, nested JSON, pools, and fourier-auth's per-md5 ask.
#     `hidden_tag_names`: the tag names that exist only on those posts, out
#     of the tag index, autocomplete and related tags.
#   - WIDEN: Post#creator_allows?, inside #levelblocked? only, from
#     `widened_ids` -- and through #visible? to can_see_media?.
#   - LOG: `log_admin_view`, an admin opening a post its creator hid (Q2): the
#     post page and the Modulation viewer's move to a post.
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
#        c. WHO THE AUDIENCE LETS IN (section 4 and Q9, operator 2026-10-07:
#           "Private should be PRIVATE, unless explicitly given permission by
#           individual name"). A NAMED user is one with an allow, creator-wide
#           or on this post. private -> :allowed for a named user, else
#           :hidden; no group ever opens it. groups -> :allowed for a member
#           of a listed group or a named user, else :hidden. public ->
#           :allowed for a member of a listed group or a named user, else
#           :default. Tiered groups NEST within one creator (Q3: tier_2 sees
#           everything tier_1 sees); an untiered group admits its members
#           only; an expired membership is no membership.
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
# A READING AWAITING A RULING (stated so it can be corrected): an unreleased
# creator's narrowing still hides, reading section 7's "nothing in the panel
# widens it" with its "a creator's restriction always narrows". It fails
# closed: a wrong reading hides too much, never shows too much.
#
# Two shapes, which must always agree (creator_visibility_test asks every case
# through each): per post (`decide`, `decisions`) and per viewer over the
# whole site (`hidden_post_ids_for`, `widened_post_ids_for`), both in a fixed
# number of queries -- no N+1. The whole-site hidden set reads the gallery
# default through the same `gallery_verdict` the per-post form uses.
module CreatorVisibility
  HIDDEN = :hidden
  ALLOWED = :allowed
  DEFAULT = :default

  BATCH_SIZE = 1000

  # What `gallery_verdict` is asked about when the question is a gallery's
  # default: no post, so no override and no per-post rule apply.
  NO_POST = Struct.new(:id).new(nil)

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

  # One request's sets, keyed by viewer. Reset by Rails at the start and end
  # of every request and job; a console or a test that changes the rows
  # mid-way calls CreatorVisibility.forget!.
  class Memo < ActiveSupport::CurrentAttributes
    attribute :sets
  end

  module_function

  # @param exempt [Boolean] false decides for an admin or a posting bot as for
  #   anyone else -- what the admin view log asks
  # @return [Symbol] :hidden, :allowed or :default -- :default for a post not
  #   yet saved, which nobody controls (as CreatorControl.controls? answers)
  def decide(post, viewer, exempt: true) = decisions([post], viewer, exempt: exempt).fetch(post.id, DEFAULT)

  # @param posts [Enumerable<Post>] each needs id and tag_string
  # @return [Hash{Integer => Symbol}] post id => decision, every saved post
  #   present
  def decisions(posts, viewer, now: Time.zone.now, exempt: true)
    posts = Array(posts).select(&:id)
    return {} if posts.empty?
    return posts.to_h { |post| [post.id, DEFAULT] } if exempt && sees_everything?(viewer)

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
  # enforcement wants, as CreatorPrefixes.hidden_post_ids_for gives.
  #
  # Decided by RULE in SQL, never post by post (2026-10-08; review: deciding
  # every post with an override one by one grew with the overrides on the
  # whole site -- a creator giving 20,000 posts a "public" override made
  # every request by every viewer decide 20,000 posts). What hides a post
  # from this viewer, per controlling gallery g, follows `gallery_verdict`:
  #
  #   - NO OVERRIDE from g: the gallery default, decided once per gallery
  #     (`gallery_verdict` on no post) -- all such posts of a gallery whose
  #     default hides, straight from the index;
  #   - a PRIVATE override: hidden unless g names this viewer creator-wide
  #     (Q9: no group opens private);
  #   - a GROUPS override: hidden unless g names this viewer creator-wide or
  #     they are a member of a listed group -- so hidden outright where they
  #     belong to none of g's groups;
  #   - a PUBLIC override: never hidden, but by a block;
  #   - a creator-wide BLOCK: everything g controls.
  #
  # Decided one by one, by `decisions`, are only the posts whose answer
  # depends on more than that: a rule naming this viewer on the post itself,
  # and a groups override in a gallery whose groups they belong to. Both
  # grow with this viewer's own relations, not with the site. A post the
  # viewer controls through any gallery is never hidden (step 2). An
  # override counts only on a post its gallery still controls (the
  # recorded creator, or a locked tag the gallery holds), as `verdict`
  # reads it. Measured on a 400,000-post dev DB with a 20,000-post private
  # gallery: deciding candidates post by post cost ~150-250 queries and
  # ~2 s a request.
  #
  # @return [Array<Integer>] sorted post ids
  def hidden_post_ids_for(viewer, now: Time.zone.now)
    return [] if sees_everything?(viewer)

    signed_in = signed_in?(viewer)
    rules = signed_in ? CreatorUserRule.where(user_id: viewer.id).pluck(:creator_gallery_id, :post_id, :rule) : []
    blocked = rules.filter_map { |gallery, post, rule| gallery if post.nil? && rule == CreatorUserRule::BLOCK }
    named = rules.filter_map { |gallery, post, rule| gallery if post.nil? && rule == CreatorUserRule::ALLOW }
    ruled_posts = rules.filter_map(&:second).uniq

    narrowing = CreatorGallery.where(default_audience: %w[groups private]).or(CreatorGallery.where(id: blocked)).pluck(:id, :matrix_id)
    overriding = CreatorPostAudience.where(audience: %w[groups private]).where.not(creator_gallery_id: named).distinct.pluck(:creator_gallery_id)
    return [] if narrowing.empty? && overriding.empty? && ruled_posts.empty?

    owned = signed_in ? CreatorGallery.where(user_id: viewer.id).pluck(:id, :matrix_id) : []
    hiding = narrowing - owned
    if hiding.any?
      snap = snapshot([], { nil => hiding.map(&:first) }, viewer, now)
      hiding = hiding.select { |gallery, _| gallery_verdict(NO_POST, [], gallery, snap) == HIDDEN }
    end
    member_of = signed_in ? CreatorGroup.where(id: CreatorGroupMembership.active(now).where(user_id: viewer.id).select(:creator_group_id)).distinct.pluck(:creator_gallery_id) : []

    one_by_one = (ruled_posts + CreatorPostAudience.where(audience: "groups", creator_gallery_id: member_of - named).pluck(:post_id)).uniq
    overriding -= owned.map(&:first)
    found = (hiding.empty? && overriding.empty?) ? [] : without_jit { Post.connection.select_values(hidden_sql(hiding, overriding, owned, blocked, member_of, one_by_one)) }.map(&:to_i)
    decided = Post.where(id: one_by_one).select(:id, :tag_string).find_in_batches(batch_size: BATCH_SIZE).flat_map do |posts|
      hidden_post_ids(posts, viewer)
    end
    (found + decided).uniq.sort
  end

  # Run a statement with Postgres's JIT compiler off, and put the setting
  # back. Postgres compiles any plan whose ESTIMATED cost passes
  # jit_above_cost; the hidden-set statement is estimated high (it hashes
  # every hidden post) but runs in tens of milliseconds, and measured on a
  # 400,000-post dev DB (2026-10-08) it spent 0.04-0.54 s compiling, every
  # request -- most of its whole cost. The connection's own setting is put
  # back however the statement ends, so nothing else is affected.
  def without_jit
    connection = Post.connection
    was = connection.select_value("SELECT current_setting('jit')")
    connection.select_value("SELECT set_config('jit', 'off', false)")
    yield
  ensure
    connection.select_value(Post.sanitize_sql_array(["SELECT set_config('jit', ?, false)", was])) if was
  end

  # hidden_post_ids_for's rule as ONE statement, whatever the number of
  # galleries (see CreatorControl.controlled_pairs_sql for what one subselect
  # per gallery cost): the posts of galleries whose default hides, without
  # those their gallery overrode (unless it blocks the viewer); the posts a
  # closed override hides, where its gallery controls them; less the
  # viewer's own posts and the posts decided one by one.
  def hidden_sql(hiding, overriding, owned, blocked, member_of, one_by_one)
    ints = ->(ids) { "'{#{ids.map { |id| Integer(id) }.join(",")}}'::bigint[]" }
    galleries = CreatorGallery.where(id: overriding).pluck(:id, :matrix_id)
    closed = <<~SQL.squish
      SELECT a.post_id, a.creator_gallery_id AS gallery_id FROM creator_post_audiences a
        WHERE a.creator_gallery_id = ANY(#{ints.call(overriding)})
          AND (a.audience = 'private' OR (a.audience = 'groups' AND a.creator_gallery_id <> ALL(#{ints.call(member_of)})))
    SQL

    # UNION ALL, and an EXCEPT only for what is there to take away: each set
    # operation hashes every row (~27,000 for a 20,000-post private gallery;
    # duplicates are dropped by the caller).
    except = []
    except << "SELECT c.post_id FROM (#{CreatorControl.controlled_pairs_sql(owned)}) c" if owned.any?
    except << "SELECT unnest(#{ints.call(one_by_one)})" if one_by_one.any?

    <<~SQL.squish
      (SELECT c.post_id FROM (#{CreatorControl.controlled_pairs_sql(hiding)}) c
        WHERE c.gallery_id = ANY(#{ints.call(blocked)})
           OR NOT EXISTS (SELECT 1 FROM creator_post_audiences a WHERE a.post_id = c.post_id AND a.creator_gallery_id = c.gallery_id AND a.audience <> 'inherit')
       UNION ALL
       SELECT c.post_id FROM (#{CreatorControl.controlled_pairs_sql(galleries, only: closed)}) c)
      #{except.map { |sql| "EXCEPT #{sql}" }.join(" ")}
    SQL
  end

  # Every GATED post its creator lets `viewer` past the site's level gate --
  # what Post#levelblocked? asks (section 7, Q1). Gated posts only, because
  # levelblocked? holds back nothing else. The candidates are the posts of the
  # galleries this viewer stands in some relation to -- their own, one whose
  # group they are in, one that named them -- since nothing else allows.
  #
  # @return [Array<Integer>] sorted post ids
  def widened_post_ids_for(viewer, now: Time.zone.now)
    return [] unless signed_in?(viewer) && !viewer.is_banned? && Danbooru.config.restricted_tags.present?
    return [] if sees_everything?(viewer)

    galleries = related_gallery_ids(viewer, now)
    return [] if galleries.empty?

    # The gated filter is SQL on the galleries' posts, never an id list
    # carried into Ruby and back (review, 2026-10-08).
    parts = CreatorControl.gallery_post_parts(CreatorGallery.where(id: galleries).pluck(:id, :matrix_id))
    gated = parts.flat_map { |part| part.where_array_includes_any("string_to_array(posts.tag_string, ' ')", Danbooru.config.restricted_tags).select(:id, :tag_string).to_a }
    gated.uniq(&:id).each_slice(BATCH_SIZE).flat_map do |posts|
      decisions(posts, viewer, now: now).select { |_, decision| decision == ALLOWED }.keys
    end.sort
  end

  # The posts hidden from `viewer`, as a Set, computed once per request.
  def hidden_ids(viewer) = memoized(:hidden, viewer) { hidden_post_ids_for(viewer).to_set }

  # The gated posts `viewer` is let past the level gate, once per request.
  def widened_ids(viewer) = memoized(:widened, viewer) { widened_post_ids_for(viewer).to_set }

  # hidden_ids as the '{1,2,3}' literal an integer[] parameter binds, or
  # nil when nothing is hidden -- built once per request, not once per query
  # that excludes them (Post.hidden_from runs once per pool row, tag search
  # and listing; review 2026-10-08).
  def hidden_ids_literal(viewer)
    memoized(:hidden_literal, viewer) do
      ids = hidden_ids(viewer)
      ids.empty? ? nil : "{#{ids.sort.join(",")}}"
    end
  end

  # The tag names carried ONLY by posts hidden from `viewer` -- what
  # Tag.hidden_names_for adds, so a tag that exists only on a creator's
  # private posts is not listed or offered as a related tag to someone those
  # posts do not exist for (section 6: "nothing new leaks"). Decided
  # 2026-10-08: a tag's post_count is a site-wide cache shared by every
  # viewer and is NOT made per viewer; a tag also carried by a post the
  # viewer can see is a tag they could find anyway.
  #
  # "Only" is read off tags.post_count, which counts deleted posts as the
  # hidden set does: a tag whose hidden posts number at least its count is on
  # nothing else. A count that has drifted low over-hides; one that has
  # drifted high shows the name, as it would have before this.
  #
  # Every tag of every hidden post, so not per request (review, 2026-10-08:
  # ~0.44 s on 27,500 hidden posts of ~30 tags each). Shared across requests
  # by every viewer with the same hidden set -- every signed-out visitor and
  # every stranger -- for TAG_NAMES_TTL, keyed on the set itself: a post
  # newly hidden is a new key at once. Within the TTL a name can be shown
  # that a moment ago was on a visible post too, or held back that just
  # gained one; neither names a hidden post the viewer could not have seen.
  # Autocomplete, which runs per keystroke, asks only its own suggestions
  # (`hidden_tag_names_among`).
  #
  # @return [Array<String>]
  TAG_NAMES_TTL = 5.minutes

  def hidden_tag_names(viewer)
    memoized(:tag_names, viewer) do
      literal = hidden_ids_literal(viewer)
      next [] if literal.nil?

      Cache.get("creator-hidden-tag-names/#{Cache.hash(literal)}", TAG_NAMES_TTL) do
        carried = Post.where("posts.id = ANY(?::integer[])", literal).select("unnest(string_to_array(posts.tag_string, ' ')) AS name")
        Tag.joins("JOIN (#{carried.to_sql}) hidden_tags ON hidden_tags.name = tags.name")
           .group("tags.name", "tags.post_count").having("count(*) >= tags.post_count").pluck("tags.name")
      end
    end
  end

  # Which of `names` exist only on posts hidden from `viewer` -- the same
  # question as hidden_tag_names, asked of a handful of names (an
  # autocomplete's suggestions) in one query, exact and uncached: a name is
  # hidden-only when no post outside the hidden set carries it. Only names
  # whose post_count the hidden set could cover are asked about at all.
  #
  # @return [Array<String>]
  def hidden_tag_names_among(viewer, names)
    names = names.compact.map(&:to_s).uniq
    literal = hidden_ids_literal(viewer) unless names.empty?
    return [] if literal.nil?

    candidates = Tag.where(name: names, post_count: 1..hidden_ids(viewer).size).pluck(:name)
    return [] if candidates.empty?

    elsewhere = Post.where("string_to_array(posts.tag_string, ' ') @> ARRAY[candidate]").where("posts.id NOT IN (SELECT unnest(?::integer[]))", literal).select(1)
    Post.connection.select_values(Post.sanitize_sql_array(["SELECT candidate FROM unnest(ARRAY[?]::text[]) AS candidate WHERE NOT EXISTS (#{elsewhere.to_sql})", candidates]))
  end

  # Would this ADMIN be refused `post` but for being an admin? Q2: "admins
  # only may view a post its creator hid; every such view is logged." An admin
  # the creator let in -- the controller, a named user, a group member -- is
  # not looking past anything.
  def hidden_but_for_admin?(post, viewer)
    signed_in?(viewer) && viewer.is_admin? && decide(post, viewer, exempt: false) == HIDDEN
  end

  # Q2's log, written by each door that is an admin OPENING a post -- the
  # post page and the Modulation viewer's client-side move to a post (GET or
  # HEAD /posts/:id/modulation?opened=1, which it sends when it SHOWS the
  # post) -- never a listing, a tooltip, the JSON, a payload fetched ahead
  # or refreshed, or a media fetch. Admin-only
  # (ModAction::ADMIN_ONLY_CATEGORIES): it names the post.
  def log_admin_view(post, viewer)
    return unless hidden_but_for_admin?(post, viewer)

    ModAction.log("viewed post ##{post.id}, which its creator hid", :creator_hidden_post_view, subject: post, user: viewer)
  end

  def forget! = Memo.reset

  # --- internals ---

  # One value per request per viewer -- the sets above, and the prefix rule's
  # own per-viewer reads (CreatorPrefixes.hidden_context and
  # hidden_post_ids_for), which every thumbnail would otherwise query again.
  # Keyed on everything a decision reads from the viewer, so a viewer object
  # changed mid-request (a ban, a level) is never answered from its old self.
  # Never older than MEMO_TTL: outside a request (a console, a runner script)
  # nothing resets the memo, and a long-lived process must re-read what it
  # decides from.
  MEMO_TTL = 30

  def memoized(kind, viewer)
    sets = (Memo.sets ||= {})
    key = [kind, viewer&.id, viewer&.level, viewer&.name, viewer&.is_banned?]
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    at, value = sets[key]
    return value if at && now - at < MEMO_TTL

    value = yield
    sets[key] = [now, value]
    value
  end

  def related_gallery_ids(viewer, now)
    owned = CreatorGallery.where(user_id: viewer.id).pluck(:id)
    grouped = CreatorGroup.where(id: CreatorGroupMembership.active(now).where(user_id: viewer.id).select(:creator_group_id)).pluck(:creator_gallery_id)
    named = CreatorUserRule.where(user_id: viewer.id, rule: CreatorUserRule::ALLOW).pluck(:creator_gallery_id)
    (owned + grouped + named).uniq
  end

  def signed_in?(viewer) = viewer.present? && !viewer.is_anonymous?

  # Admins and the posting bots. The editors are read through the visibility
  # copy of the list, which keeps the last good one when the file breaks.
  def sees_everything?(viewer)
    signed_in?(viewer) && (viewer.is_admin? || CreatorPrefixes.visibility_config[:editors].include?(viewer.name))
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
    named = rules.include?(CreatorUserRule::ALLOW)

    # Q9: private lets in the users named, and no group; groups-only and
    # public let in a listed group's members and the users named.
    let_in = named || (audience != "private" && groups.any? { |group| member?(group, snap) })
    return HIDDEN if audience != "public" && !let_in
    return DEFAULT unless let_in

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
