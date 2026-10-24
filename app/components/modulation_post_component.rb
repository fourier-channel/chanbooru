# frozen_string_literal: true

# "Modulation" -- the redesigned single-cell post page (fourier fork). An opt-in
# experience preset rendered when ?preset=modulation is present; the upstream
# post page stays the default. Everything visual is token-driven (CSS custom
# properties) so a preset is just a bundle of overrides.
#
# Tag provenance comes from FourierTagSource.for_viewer, which is already
# identity-gated: creator-only (prompt-derived, private) tags go to the post's
# creator alone, no moderator or admin included (FourierCreatorPrivacy), and a
# tag on the post's public list shows to everyone, even where the creator's
# private prompt row names it too (operator ruling 2026-10-19). The component
# renders whatever it is handed -- the privacy decision lives in the model,
# not the view.
class ModulationPostComponent < ApplicationComponent
  attr_reader :post, :viewer, :query, :settings

  # unsourced last: it is the bucket for a tag whose origin was never
  # recorded, so it says the least and should not lead the row.
  BUCKET_ORDER = %i[creator both auto pending unsourced].freeze

  # How many more keyset reads a flank side may take to replace candidates
  # this viewer may not see (build_nav_presets). Bounded: a run longer than
  # this is sent as it stands, `more` still true.
  FLANK_FILL_ROUNDS = 3

  # `settings` is the viewer's Modulation view state (ModulationSetting.for_viewer);
  # callers with no session context get the defaults so the component stays
  # renderable anywhere.
  # `session` is only for random mode's trail (RandomTrail): an anonymous
  # viewer's history lives in it. Absent, random still renders -- fresh picks,
  # remembered nowhere -- so the component stays renderable anywhere.
  # `request` is for the creator check (FourierCreatorPrivacy): the viewer's
  # VERIFIED Matrix identity rides on it (FourierIdentity), and the post's
  # creator alone sees its private creator tags and generation data. Absent,
  # the current request is used, and outside one no Matrix identity matches.
  # Held under its own name because ViewComponent owns `request` and answers
  # it only once rendering has begun, and the navigation endpoint builds the
  # payload without rendering at all.
  # `read` is which read of the payload this is (ModulationController):
  # :full, the page itself and a re-read; :prefetch, a neighbour's payload
  # fetched AHEAD of the viewer, which is not a visit, so random's trail never
  # takes the post (random_neighbours); :visit, the read the page makes once
  # the viewer lands on a prefetched post -- random's preset alone, which
  # records the visit (#visit_payload).
  def initialize(post:, viewer:, query: nil, settings: nil, session: nil, request: nil, read: :full) # rubocop:disable Metrics/ParameterLists
    super
    @post = post
    @viewer = viewer
    @query = query
    @settings = settings || ModulationSetting.defaults
    @session = session
    @identity_request = request
    @read = read
  end

  # The request the creator check reads the viewer's Matrix identity from.
  def identity_request
    @identity_request || CurrentUser.request
  end

  # --- gallery navigation -------------------------------------------------
  # The navigation MODES offered for this post (operator ruling 2026-09-04:
  # "post#/date is the only true axis, and everything else is just filters
  # given names as modes"). Every mode walks the same chronological axis
  # under a different filter -- the search you arrived with, the creator's
  # gallery, the whole archive -- and every mode tracks your position, so
  # switching modes is switching filters, not losing your place. The one
  # exception that changes the AXIS rather than the filter is random.
  def nav_presets
    @nav_presets ||= build_nav_presets
  end

  # The preset matching the sort the viewer arrived with (default: by number).
  def active_preset_key
    @active_preset_key ||= (nav_presets.find { it[:active] } || nav_presets.first)&.fetch(:key)
  end

  # ------------------------------------------------------------------------

  # { creator:, auto:, both:, meta:, pending: } -- creator already privacy-gated.
  # Banished names are then withheld from DISPLAY for everyone without the
  # admin reveal toggle; blacklist_data keeps them, because matching is not
  # display and the enforced rules must still see them.
  def buckets
    tag_view.first
  end

  # The lamps, tag name lists per model, filtered by the same banishment gate.
  # They come back beside the buckets rather than inside them -- see
  # FourierTagSource.lamps_for for what happened the evening they did not.
  def lamps
    tag_view.last
  end

  def tag_view
    @tag_view ||= begin
      raw = FourierTagSource.buckets_and_lamps_for(post, viewer, request: identity_request)
      raw.map { |h| h.transform_values { |names| TagBanishment.filter(names, viewer) } }
    end
  end

  # Danbooru-category keys worth a bucket of their own at the head of the tag
  # list. Species is not a category this booru has (the fork carries stock
  # upstream categories); if one is ever added it joins this map and the
  # client renders it with no further change.
  CATEGORY_KEYS = {
    TagCategory::ARTIST => :artist,
    TagCategory::CHARACTER => :character,
    TagCategory::COPYRIGHT => :copyright,
  }.freeze

  # { artist: [...], character: [...], copyright: [...] } -- only keys with
  # tags present. Built from the VIEWER-VISIBLE tags (the buckets), never from
  # tag_string: the buckets are what this viewer may see -- the public list,
  # and for the post's creator their private tags too -- and a category
  # lookup must not become a second door past that gate.
  # Every name here also appears in `buckets`; the client uses that to keep
  # provenance styling and to drop these from the general flow.
  def category_tags
    @category_tags ||= begin
      visible = buckets.values.flatten.uniq
      categories = Tag.categories_for(visible)
      visible.each_with_object({}) do |name, out|
        key = CATEGORY_KEYS[categories[name]]
        (out[key] ||= []) << name if key
      end
    end
  end

  # Whose each claimed original character is (CharacterClaim): tag =>
  # { name:, href: }, for the character pills only, which hold only tags this
  # viewer can see. No query without a character tag; one with (a signed-out
  # viewer's name is the @slug already in the tag).
  def oc_owners
    @oc_owners ||= CharacterClaim.owners(category_tags[:character].to_a, viewer)
  end

  # The colour-coded unitag row, in a deliberate order (creator, both, auto,
  # pending); meta lives in its own collapsible section, not here.
  def unitag_pills
    BUCKET_ORDER.flat_map { |b| buckets[b].to_a.map { |tag| [tag, b] } }
  end

  def meta_tags
    buckets[:meta].to_a
  end

  def any_tags?
    unitag_pills.any? || meta_tags.any?
  end

  # One-line mono metadata sub-header pieces (label-less; order carries meaning).
  def metadata_fields
    [
      "#{post.image_width}\u00d7#{post.image_height}",
      ActiveSupport::NumberHelper.number_to_human_size(post.file_size),
      ".#{post.file_ext}",
      post.created_at.strftime("%Y-%m-%d"),
      "@#{post.uploader.name}",
    ]
  end

  def media_gated?
    post.source.to_s.start_with?("mxc://")
  end

  def comments_enabled?
    Danbooru.config.comments_enabled?.to_s.truthy?
  end

  # What the client-side blacklist matches this post against. Same contract as
  # the gallery cards, and the same reason data-tags is not post.tag_string:
  # the post's creator also matches on their private tags, which tag_string
  # does not carry (FourierTagSource.blacklist_tags_for).
  def blacklist_data
    blacklist_attrs(post, blacklist_tags)
  end

  # The engine's contract for any post, given its viewer-safe tags
  # (FourierTagSource.blacklist_tags_for). The flank candidates are built with
  # it too, so a candidate carries exactly what its own page would.
  def blacklist_attrs(target, tags)
    {
      "data-id" => target.id,
      "data-tags" => tags.join(" "),
      "data-rating" => target.rating,
      "data-flags" => target.status_flags,
      "data-score" => target.score,
      "data-uploader-id" => target.uploader_id,
    }
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for([post], viewer, request: identity_request).fetch(post, [])
  end

  # --- parity with the upstream post page ---------------------------------
  # Everything below exists because the upstream page had it and this one did
  # not. A viewer who moves between a themed listing and this page should not
  # discover that scoring, favouriting, flagging or the reason a post is in the
  # modqueue are things that only happen on the other interface.

  def policy
    @policy ||= PostPolicy.new(viewer, post)
  end

  def anonymous?
    viewer.nil? || viewer.is_anonymous?
  end

  def current_vote
    return @current_vote if defined?(@current_vote)

    # Deliberately NOT post.vote_by_current_user: that association reads the
    # CurrentUser thread-global, and this component is also rendered from the
    # navigation endpoint where the viewer is passed in explicitly.
    @current_vote = anonymous? ? nil : PostVote.active.find_by(post: post, user: viewer)
  end

  def score_payload
    vote = current_vote
    {
      total: post.score,
      up: post.up_score,
      down: post.down_score,
      vote: vote && (vote.is_positive? ? "up" : "down"),
      vote_id: vote&.id,
      can_vote: !anonymous?,
    }
  end

  def fav_payload
    { count: post.fav_count, faved: post.favorited_by?(viewer), can_fav: !anonymous? }
  end

  def jailed?
    post.has_tag?(Danbooru.config.troll_jail_tag)
  end

  # The reason recorded on the deletion flag, as a sentence, or nil.
  def deletion_reason
    reason = post.flags.succeeded.last&.reason.to_s.strip
    return nil if reason.blank?

    reason.end_with?(".") ? "Reason: #{reason}" : "Reason: #{reason}."
  end

  # One word for the post's moderation state, shown in the metadata line.
  def status
    return "banned" if post.is_banned?
    return "deleted" if post.is_deleted?
    return "flagged" if post.is_flagged?
    return "appealed" if post.is_appealed?
    return "pending" if post.is_pending?

    "active"
  end

  # The notice strip above the image: the things upstream put in coloured boxes
  # -- why a post is in the modqueue, that it was deleted, that it has a parent
  # or children. Navigation between related posts is the reason the parent and
  # child notices matter most; without them a post family is invisible here.
  def notices
    list = []

    # First, above the deletion notice, because it is the REASON for it: an
    # operator sent this image to troll jail from the curation surface, and the
    # deletion is that decision arriving on the booru. Driven by the tag rather
    # than by the deleted flag, so a jailing whose delete half failed still says
    # so -- which is exactly the state 38 posts were in when this was written.
    list << { kind: "jailed", text: "This post is in troll jail." } if jailed?

    case status
    when "banned"
      list << { kind: "banned", text: "This post was removed following a takedown request or rule violation." }
    when "deleted"
      # With the reason, when there is one. The deletion flag carries the
      # operator's own words ("troll jail: shock"), and a deletion nobody can
      # account for later is the thing the reason exists to prevent.
      list << { kind: "deleted", text: ["This post was deleted.", deletion_reason].compact.join(" ") }
    when "pending"
      list << { kind: "pending", text: "This post is pending approval." }
    when "flagged"
      list << { kind: "pending", text: "This post was flagged and is pending approval." }
    when "appealed"
      list << { kind: "pending", text: "This post was appealed and is pending approval." }
    end

    # Only a parent and children that exist for this viewer are named, by
    # the one rule the post page's notices use (Post#relatives_shown_to;
    # review, 2026-10-08: a deleted child made a hidden live one announce
    # itself here while the page said nothing).
    relatives = post.relatives_shown_to(viewer)
    if relatives[:parent].present?
      list << {
        kind: "parent",
        text: "This post belongs to a parent.",
        href: routes.post_path(post.parent_id),
        label: "view parent ##{post.parent_id}",
      }
    end

    if post.has_visible_children? && relatives[:children].any?
      list << {
        kind: "child",
        text: "This post has children.",
        href: routes.posts_path(tags: "parent:#{post.id}"),
        label: "view children",
      }
    end

    list
  end

  # The long tail of upstream's sidebar "Options" and "History" sections. They
  # live behind a disclosure rather than in the action row: this page is a
  # single-cell viewer by design, and putting twenty links permanently on screen
  # would undo that. Behind one control they are still reachable, which is the
  # part that was actually missing.
  def more_links
    groups = []

    # "Find similar" only when IQDB is actually configured. Upstream shows the
    # link unconditionally, which is survivable in a sidebar nobody had to look
    # at; offering a dead link from the default view of every post is not.
    discover = []
    discover << { label: "Find similar", href: routes.iqdb_queries_path(post_id: post.id) } if Danbooru.config.iqdb_url.present?
    # A post can outlive its media asset (expunged file, failed import), so this
    # one is asked for rather than assumed.
    asset_id = post.media_asset&.id
    discover << { label: "Media asset", href: routes.media_asset_path(asset_id) } if asset_id
    discover << { label: "Comments", href: "#mod-comments", local: true }
    groups << { label: "discover", links: discover }

    if policy.update?
      # A PLAIN ANCHOR ON THIS PAGE. These used to carry
      # ?preset=historical&preset_sticky=0, sending the viewer to the upstream
      # interface because Modulation had no form of its own -- a detour that
      # was never meant to be permanent.
      #
      # Operator ruling 2026-09-20: "Nothing should be preset=historical."
      # posts/show.html.erb now renders the same upstream edit partial inside
      # the Modulation page, so #edit resolves here and the link stays put.
      # That render is what makes this safe: without it these are dead
      # anchors, because #edit exists in the historical branch and nowhere
      # else.
      groups << { label: "contribute", links: [
        { label: "Edit tags", href: "#edit", local: true },
        { label: "Add to pool", href: "#edit", local: true },
        { label: "Add commentary", href: "#edit", local: true },
      ] }
    end

    report = []
    report << { label: "Flag", href: routes.new_post_flag_path(post_flag: { post_id: post.id }) } if post.is_active?
    report << { label: "Appeal", href: routes.new_post_appeal_path(post_appeal: { post_id: post.id }) } if post.is_appealable?
    groups << { label: "report", links: report } if report.any?

    # Who sees this post, for the people who may change it -- the creator
    # panel's link (2026-10-09). Read-only here: an audience belongs to each
    # controlling creator, not to the post, so it is set on their panel.
    if audience_payload
      groups << { label: "who sees this", links: audience_payload.map { |a| { label: "#{a[:words]} - change", href: a[:href] } }}
    end

    groups << { label: "history", links: [
      { label: "Tags", href: routes.post_versions_path(search: { post_id: post.id }) },
      { label: "Notes", href: routes.note_versions_path(search: { post_id: post.id }) },
      { label: "Pools", href: routes.pool_versions_path(search: { post_id: post.id }) },
      { label: "Moderation", href: routes.post_post_events_path(post.id) },
    ] }

    groups
  end

  # Everything the client needs to render this post in the Modulation view, as a
  # plain hash so the same builder serves the initial embed AND the client-side
  # navigation endpoint (no page reload). Tag buckets come from for_viewer, so the
  # creator-privacy decision stays server-side -- the client only displays what it
  # is handed. Context-free (no view helpers) so it works outside a render.
  # The keys of each preset the page is sent (payload, visit_payload).
  PRESET_KEYS = %i[key label search prev_candidates next_candidates prev_more next_more history unavailable deferred].freeze

  # THE VISIT READ: what a prefetched payload lacks, and nothing else -- random's
  # preset, built as a visit (the post pushed onto the trail, its frontier
  # rolled), that preset's candidates, and (the controller) the comment
  # section. The page merges it into the payload it is showing
  # (FourierPayloads.mergeVisit). It used to ask for the whole payload again,
  # which doubled the builds per step -- every keyset mode's searches, the
  # tags, the counts -- to learn these two things (review, 2026-10-18).
  def visit_payload
    { id: post.id, presets: nav_presets.map { |p| p.slice(*PRESET_KEYS) }, candidates: flank_candidates }
  end

  def payload
    {
      id: post.id,
      url: post_url_for(post, query.presence),
      media: media_payload,
      meta: meta_payload,
      gated: media_gated?,
      tags: buckets,
      lamp: lamps,
      # MAY THIS VIEWER EDIT THE POOL. The same policy that gates the
      # "contribute" links and the edit section, so the three cannot disagree.
      # The client never decides this: a hidden control is a courtesy, and the
      # write is authorised again at /posts/:id.
      can_edit: policy.update?,
      cat_tags: category_tags,
      # "by <creator>" beside a claimed original character's pill.
      oc_owners: oc_owners,
      settings: settings,
      # Each side of each mode is a list of candidate refs ({id, url}),
      # nearest first; the page shows the first the viewer's blocklist allows
      # and re-picks live when a block changes (GALLERY_WINDOW.md section 2).
      # `more` says whether the search goes on past the list. New key names,
      # not prev/next with a new shape: a tab left open across a deploy then
      # draws empty flanks rather than navigating to "undefined". `deferred`
      # is random's on a prefetch of a post its trail does not hold.
      presets: nav_presets.map { |p| p.slice(*PRESET_KEYS) },
      # id => { thumb:, deleted:, blacklist:, media: } for every candidate
      # above, once however many modes share it. `blacklist` is what the
      # engine matches, built as the centre's is; the page writes it onto
      # hidden pool elements, because the engine only sees elements. `media`
      # is what that post's own payload names, so the page can warm its
      # picture before fetching its payload.
      candidates: flank_candidates,
      active_key: active_preset_key,
      status: status,
      rating: post.rating,
      score: score_payload,
      fav: fav_payload,
      notices: notices,
      more: more_links,
      # The blacklist is applied to the root element, so navigating without a
      # reload has to hand the client the next post's attributes too -- otherwise
      # the blacklist keeps matching the post the viewer arrived on.
      blacklist: blacklist_data,
      can_browse: can_browse?,
      # Q2's log (CreatorVisibility.log_admin_view): true only for an admin
      # this post's creator hid it from. The client fetches payloads ahead of
      # time (the neighbours) and again after a vote or a favourite, none of
      # which is the admin opening the post, so the payload request logs
      # nothing by itself; the client says when it actually shows this post
      # (?opened=1, ModulationController#show). Review, 2026-10-08.
      logs_admin_view: CreatorVisibility.hidden_but_for_admin?(post, viewer),
      # The creator lamps: which of this post's artist tags are active now,
      # and the window that means. The page polls /modulation/creator_activity
      # to keep them honest while it stays open.
      live_creators: CreatorActivity.active(category_tags[:artist].to_a, viewer: viewer),
      live_window: Danbooru.config.creator_active_window.to_i,
      # The ( jail | delete ) pill: what the post is, and whether this viewer
      # may change it. The rule between the two switches -- jailed implies
      # deleted, deleted does not imply jailed -- is enforced by
      # ModulationModerationController; the pill only shows it.
      moderation: { can: policy.moderate?, jailed: jailed?, deleted: post.is_deleted? },
      # The prompt, settings and workflow the tunnel took out of this image
      # (operator ruling 2026-09-28), or nil. nil for everyone but the creator
      # (ruling 2026-09-29), and nil when there is nothing -- the two are not
      # told apart.
      generation: generation_payload,
      # Who sees this post, one entry per controlling creator this viewer may
      # set it for (their own, or every one for an admin), or nil -- nil for
      # everyone else, a moderator included (Q2).
      audience: audience_payload,
      # The review quarantine's quick switch on each pill (TagQuarantine):
      # admins only, nil for everyone else, so no one below admin is told a
      # tag id or which names are flagged.
      quarantine: quarantine_payload,
      # Which pills link to a tag search: nil for every one (a member), else
      # the names a signed-out viewer may open a search for -- a featured
      # creator's tag (MembersOnly.anonymous_post_listing). Every other pill
      # is drawn as a label rather than a link that 404s (2026-10-13).
      tag_links: tag_links,
    }
  end

  # @return [Array<String>, nil] see payload[:tag_links]. Asked of the viewer,
  #   not the request (this builder is context-free): a non-member under the
  #   default-deny is a signed-out viewer here.
  def tag_links
    return nil unless MembersOnly.default_deny? && !MembersOnly.member?(viewer)

    featured = MembersOnly.anonymous_featured_tags
    post.tag_array.select { |name| featured.include?(name) }
  end

  # @return [Hash, nil] tag_ids: {name => id} for this post's tags (one
  #   pluck), flagged: the names on it that are flagged -- for an admin; nil
  #   for anyone else
  def quarantine_payload
    return nil unless Pundit.policy!(viewer, Tag).can_change_quarantine?

    names = post.tag_array
    { tag_ids: Tag.where(name: names).pluck(:name, :id).to_h, flagged: names.select { |name| TagQuarantine.flagged_names.include?(name) }}
  end

  # @return [Array<Hash>, nil] { words:, href: } per controlling gallery the
  #   viewer manages (CreatorGallery#managed_by?), nil when there is none
  def audience_payload
    return @audience_payload if defined?(@audience_payload)
    return @audience_payload = nil if viewer.nil? || viewer.is_anonymous? || viewer.is_banned?
    # Only an admin or the owner of a page can manage one (managed_by?): for
    # every other member -- on every payload fetch and prefetch -- the answer
    # is nil before anything asks who controls the post. Once per request.
    return @audience_payload = nil unless viewer.is_admin? || CreatorVisibility.memoized(:owns_gallery, viewer) { CreatorGallery.exists?(user_id: viewer.id) }

    ids = CreatorControl.controller_gallery_ids([post]).fetch(post.id, [])
    galleries = ids.empty? ? [] : CreatorGallery.where(id: ids).order(:id).select { |gallery| gallery.managed_by?(viewer) }
    return @audience_payload = nil if galleries.empty?

    overrides = CreatorPostAudience.where(post_id: post.id, creator_gallery_id: galleries.map(&:id)).pluck(:creator_gallery_id, :audience).to_h
    names = CreatorAudienceGroup.joins(:creator_group).where(creator_groups: { creator_gallery_id: galleries.map(&:id) }, post_id: [nil, post.id])
                                .order("creator_groups.name").pluck("creator_groups.creator_gallery_id", :post_id, "creator_groups.name", "creator_groups.tier")
    @audience_payload = galleries.map do |gallery|
      own = overrides[gallery.id].presence_in(%w[public groups private])
      listed = names.select { |gid, pid, _, _| gid == gallery.id && pid == (own ? post.id : nil) }.map { |*, name, tier| CreatorGroup.label(name, tier) }
      whose = (gallery.user_id == viewer.id) ? "your default" : "#{gallery.title.presence || gallery.slug}'s default"
      words = CreatorGallery.audience_words(own || gallery.default_audience, listed)
      { words: "#{words} (#{own ? "post setting" : whose})", href: routes.edit_creator_gallery_path(gallery, post_id: post.id, anchor: "creator-panel-posts") }
    end
  end

  # This post's generation data, if a record is served for this post
  # (FourierGenerationMetadata.for_post: its owner is the post's recorded
  # creator) AND this viewer may read it (FourierCreatorPrivacy: the post's
  # creator -- not an admin). The whole decision is made here; the client
  # only draws what it is handed, as escaped text.
  def generation_payload
    record = FourierGenerationMetadata.for_post(post)
    return nil unless record && FourierCreatorPrivacy.visible_to?(post, viewer, identity_request)

    # Sorted by key: jsonb keeps its own key order (shortest first), not the
    # order the tunnel sent, so any order shown has to be chosen here.
    { source: record.source, fields: record.fields.sort }
  end

  # Rails' route helpers, for the payload builders above. Kept as one reader so
  # the "context-free, no view helpers" contract stays easy to see.
  def routes
    Rails.application.routes.url_helpers
  end

  private

  # The centre's media -- and each flank candidate's (build_nav_presets), so a
  # picture the page warms ahead from a candidate is byte for byte the URL its
  # own page asks for. `box` is the exact size of the rendition `src` names:
  # the stage reserves it before the bytes arrive, so nothing moves when they
  # do (operator, 2026-10-18). Absent where that size is unknown -- flash's
  # placeholder, a picture this viewer may not see -- and the stage falls back
  # to the placeholder's own. w/h stay the original's, for the fullscreen fit.
  #
  # `full`, the tagged original for "View original" and the fullscreen viewer,
  # is the centre's alone: its file name is built from the post's tags
  # (seo_tags), one tags query per post, and a candidate never shows it
  # (`centre: false`) -- 12 to 48 candidates a payload made 12 to 48 queries.
  def media_payload(target = post, centre: true)
    asset = target.media_asset
    visible = target.visible?(viewer)
    if target.is_image?
      # A post with a sample is pointed at its 720 rendition: production's gate
      # snaps the booru route's ?w=850 to that webp anyway (fourier-auth
      # booru-media.js pickVariant), so this names the picture actually served
      # and its true size -- and dev, which serves the sample itself, shows the
      # same rendition. NOT a Matrix-sourced post: its route (the gate's
      # /media, mediar2.js booruVariantKey) keeps ?width=850 at 850 and serves
      # the 850 sample, so the 720 would be a smaller, softer picture than it
      # showed before (review, 2026-10-18). It keeps its sample.
      rendition = target.source.to_s.start_with?("mxc://") ? :sample : :"720x720"
      shown = asset.variant(asset.has_variant?(:sample) ? rendition : :original)
      { kind: "image", src: (visible ? shown.file_url : nil), full: ((visible && centre) ? target.tagged_file_url : nil), w: target.image_width, h: target.image_height, box: (visible ? [shown.width, shown.height] : nil) }
    elsif target.is_video?
      { kind: "video", src: (visible ? target.file_url : nil), poster: (visible ? target.preview_file_url : nil), w: target.image_width, h: target.image_height, box: (visible ? [asset.image_width, asset.image_height] : nil) }
    else
      # ugoira / flash / other: Modulation shows the preview + a link out. The
      # preview is the 180 rendition; flash has none (a fixed placeholder).
      preview = asset.variant(:"180x180")
      { kind: "other", src: (visible ? target.preview_file_url : nil), href: post_url_for(target, nil), w: target.image_width, h: target.image_height, box: ((visible && preview) ? [preview.width, preview.height] : nil) }
    end
  rescue StandardError => e
    DanbooruLogger.log(e)
    { kind: "other", src: nil, href: post_url_for(target, nil) }
  end

  # Rating rides in the metadata line rather than the action row: it is a
  # property of the post, not something you do to it. Status only appears when
  # it is not "active" -- a badge that is always there stops being read.
  #
  # THE LINE NEVER WRAPS (operator, 2026-10-18: nothing above the stage moves
  # between posts), so what is past its width is scrolled to. The fields that
  # say the post's state come first -- status, rating, source -- and the file's
  # numbers and the uploader after them, so the part a narrow screen cuts off
  # is never the part that matters (review, 2026-10-18).
  def meta_payload
    [
      ({ text: status, status: true } unless status == "active"),
      { text: "rating:#{post.rating}" },
      ({ text: "source", href: post.normalized_source } if post.source.present? && post.normalized_source.present?),
      *metadata_fields.map { |text| { text: text } },
    ].compact
  end

  # The viewer's current search with any order: stripped, so each preset applies
  # its own sort over the same result set they were browsing.
  def base_tags
    @base_tags ||= query.to_s.gsub(/\border:\S+/i, "").squish
  end

  def artist_names
    @artist_names ||= post.tags.select(&:artist?).map(&:name)
  end

  def with_order(tags, order)
    [tags.presence, "order:#{order}"].compact.join(" ").squish
  end

  # Whether this viewer may walk the archive from here. A restricted viewer can
  # see this post -- they were given a link to it -- but the post page is not a
  # doorway into everything else.
  def can_browse?
    viewer.present? && viewer.can_browse_freely?
  end

  def build_nav_presets
    # No neighbours for a restricted viewer: the modes and the flank previews
    # ARE the browsing this tier does not have. Withholding them here rather
    # than letting the links 410 means the restriction reads as a boundary
    # instead of as a broken page.
    return [] unless can_browse?

    incoming_order = PostQuery.new(query.to_s).find_metatag(:order).presence&.downcase

    defs = []
    # The filter modes, every one on the chronological axis. "search" is the
    # exact search the viewer arrived with, order stripped -- the grid's sort
    # is the GRID's business; walking post-to-post is chronological.
    defs << { key: "search", label: "search", search: with_order(base_tags, "id_desc") } if base_tags.present?
    if artist_names.any?
      artist_search = (base_tags.split + [artist_names.first]).uniq.sort.join(" ")
      # When the arriving search IS the creator's gallery, one row says so --
      # two identical filters under different names is a lie about the axis.
      defs << { key: "creator", label: "creator", search: with_order(artist_search, "id_desc") } unless artist_search == base_tags.split.uniq.sort.join(" ")
    end
    defs << { key: "all", label: "all", search: with_order(nil, "id_desc") }
    # The one mode that changes the AXIS instead of the filter.
    defs << { key: "random", label: "random", search: with_order(base_tags, "random") }
    # A visit read wants random alone (visit_payload): the keyset modes are in
    # the prefetched payload the page is already showing.
    defs = defs.select { it[:key] == "random" } if @read == :visit

    resolved = defs.map do |d|
      if d[:key] == "random"
        d.merge(random_neighbours).merge(order: "random")
      else
        # A mode whose query can't run (e.g. exceeds the viewer's tag limit)
        # must degrade to "no neighbours", never 500 the whole view -- and
        # say so, to the log and to the page (`unavailable`).
        nav = PostNeighbors.new(post: post, tags: d[:search], user: viewer)
        before = nav.run(:prev)
        after = nav.run(:next)
        d.merge(prev_ids: before[:ids], next_ids: after[:ids], prev_more: before[:more], next_more: after[:more], order: nav.order)
      end
    rescue StandardError => e
      DanbooruLogger.log(e)
      d.merge(prev_ids: [], next_ids: [], prev_more: false, next_more: false, order: "id_desc", unavailable: true)
    end

    # One batched load for every candidate across every mode, and one batched
    # tag read for the ones this viewer may see -- not a query per preview.
    ids = resolved.flat_map { it[:prev_ids] + it[:next_ids] }.uniq
    posts_by_id = Post.where(id: ids).includes(:media_asset).index_by(&:id)
    shown_ids = posts_by_id.values.select { |neighbour| flank_shown?(neighbour) }.to_set(&:id)

    # A side thinned below DEPTH by posts this viewer may not see -- the
    # search finds an artist-banned post, visible? does not -- is topped up
    # by reading on from its last ROW. That row's id stays here: the page
    # only ever holds shown candidates, so a side the server emptied left it
    # nothing to look further from, and every post past the run was out of
    # reach in that mode. Random is a trail, not a keyset, and is not topped.
    resolved = resolved.map do |d|
      next d if d[:key] == "random" || d[:unavailable]

      %i[prev next].reduce(d) do |acc, side|
        rows = acc[:"#{side}_ids"]
        more = acc[:"#{side}_more"]
        FLANK_FILL_ROUNDS.times do
          break unless more && rows.count { shown_ids.include?(it) } < PostNeighbors::DEPTH && posts_by_id.key?(rows.last)

          found = PostNeighbors.new(post: posts_by_id[rows.last], tags: acc[:search], user: viewer).run(side)
          fresh = Post.where(id: found[:ids] - posts_by_id.keys).includes(:media_asset).index_by(&:id)
          posts_by_id.merge!(fresh)
          shown_ids.merge(fresh.values.select { |neighbour| flank_shown?(neighbour) }.map(&:id))
          rows += found[:ids]
          more = found[:more]
        end
        listed = rows.select { shown_ids.include?(it) }
        # Past the DEPTH-th shown row there is more, whatever the last read said.
        more ||= listed.size > PostNeighbors::DEPTH || (listed.size == PostNeighbors::DEPTH && rows.last != listed.last)
        acc.merge("#{side}_ids": listed.first(PostNeighbors::DEPTH), "#{side}_more": more)
      end
    end

    listed = resolved.flat_map { it[:prev_ids] + it[:next_ids] }.uniq.filter_map { posts_by_id[it] if shown_ids.include?(it) }
    tags = FourierTagSource.blacklist_tags_for(listed, viewer, request: identity_request)
    @flank_candidates = listed.to_h do |neighbour|
      [neighbour.id, { thumb: neighbour.preview_file_url, deleted: neighbour.is_deleted?, blacklist: blacklist_attrs(neighbour, tags.fetch(neighbour, [])), media: media_payload(neighbour, centre: false).slice(:kind, :src, :poster, :box) }]
    end

    if incoming_order == "random"
      active_key = "random"
    elsif base_tags.present?
      active_key = "search"
    else
      active_key = "all"
    end

    resolved.map do |d|
      refs = ->(list) { list.filter_map { |id| { id: id, url: post_url_for(posts_by_id[id], d[:search]) } if @flank_candidates.key?(id) } }
      d.merge(
        active: d[:key] == active_key,
        prev_candidates: refs.call(d[:prev_ids]),
        next_candidates: refs.call(d[:next_ids]),
      )
    end
  end

  # See payload[:candidates]: empty for a viewer with no neighbours.
  def flank_candidates
    nav_presets
    @flank_candidates || {}
  end

  # Random's neighbours ARE random -- PostNeighbors' id-walk fallback would
  # make "random" a deterministic stroll, which is the exact confidence trick
  # the mode redesign exists to end. But random has a HISTORY (RandomTrail,
  # operator 2026-09-19): a post already on the viewer's trail keeps the
  # neighbours it had, and only the frontier -- the far side of the last post
  # seen in that direction -- is rolled, once, and remembered. Re-rolling
  # both sides on every payload, which is what this did, made "back" a
  # different random post than the one just left. The flank candidates are
  # the trail's entries either side; past the first fresh one, the page's
  # next hop rolls again (RandomTrail#neighbours_for).
  #
  # A ROLL IS DANBOORU'S OWN Post.random -- a random md5, then the nearest
  # matching post along the md5 index -- never ORDER BY random() over the whole
  # search. That sort evaluated every tag exclusion the search carried (then
  # including the since-removed enforced list) against every visible
  # post: 44 seconds for one roll on production data (2026-09-26), paid by
  # every signed-in post view whatever its mode. Every roll excludes what was
  # already rolled -- the trail passes its ids, and the trail-less branch
  # passes prev -- which keeps the two sides different AND keeps their SQL
  # different: a request caches identical SQL, and twenty cached rolls of one
  # query came back as one post twenty times
  # (test/unit/modulation_random_neighbours_test.rb).
  #
  # A PREFETCH IS NOT A VISIT: it never pushes its post onto the trail. A post
  # the trail does not hold is sent `deferred` -- empty, nothing rolled -- and
  # the page fills it from the visit read it makes once the viewer lands
  # (visit_payload). A post the trail holds is answered from it, and at an end
  # its frontier is rolled: that is the next random post in the direction the
  # viewer is walking, and deferring it made every forward step along random
  # wait on a second build after the landing (review, 2026-10-18).
  def random_neighbours
    roll = ->(taken) { Post.user_tag_match(base_tags.to_s, viewer, row_filter: true).where.not(id: taken + [post.id]).random(1).pick(:id) }
    trail = random_trail
    if trail && @read == :prefetch && !trail.holds?(post)
      { prev_ids: [], next_ids: [], prev_more: true, next_more: true, history: trail.size, deferred: true }
    elsif trail
      found = trail.neighbours_for(post, depth: PostNeighbors::DEPTH, &roll)
      trail.save!
      found.merge(history: trail.size)
    else
      # Remembered nowhere: one fresh roll a side, and more wherever a roll
      # found something.
      prev_id = roll.call([])
      next_id = roll.call([prev_id].compact)
      { prev_ids: [prev_id].compact, next_ids: [next_id].compact, prev_more: !prev_id.nil?, next_more: !next_id.nil?, history: 0 }
    end
  rescue StandardError => e
    DanbooruLogger.log(e)
    { prev_ids: [], next_ids: [], prev_more: false, next_more: false, history: 0, unavailable: true }
  end

  def random_trail
    return nil if @session.nil? && (viewer.nil? || viewer.is_anonymous?)

    @random_trail ||= RandomTrail.for(viewer, @session, base_tags)
  end

  # Whether a candidate may be offered at all. Not when the post is hidden
  # from this viewer (Post#hidden_from?: deleted, jailed, gated, under a
  # hidden creator prefix) nor when it is not visible? -- the side strip
  # asked only visible?, so an admin who can see deleted posts got a jailed
  # neighbour's thumbnail sharp beside a centre that blurs it (operator,
  # 2026-10-07). Such a candidate is DROPPED, not sent without a thumbnail:
  # a blank tile is no destination, and its id and tags are not this
  # viewer's to have. A deleted neighbour the viewer may see is offered and
  # flagged, and the strip blurs it as the gallery grid does.
  def flank_shown?(neighbour)
    neighbour.visible?(viewer) && !neighbour.hidden_from?(viewer)
  rescue StandardError => e
    DanbooruLogger.log(e)
    false
  end

  # Route helper that works outside a render context (used by the JSON endpoint).
  def post_url_for(target, search)
    Rails.application.routes.url_helpers.post_path(target, q: search.presence)
  end
end
