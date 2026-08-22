# frozen_string_literal: true

# "Modulation" -- the redesigned single-cell post page (fourier fork). An opt-in
# experience preset rendered when ?preset=modulation is present; the upstream
# post page stays the default. Everything visual is token-driven (CSS custom
# properties) so a preset is just a bundle of overrides.
#
# Tag provenance comes from FourierTagSource.for_viewer, which is already
# identity-gated: creator-only (prompt-derived, private) tags are withheld unless
# the viewer is the creator or a moderator. The component renders whatever it is
# handed -- the privacy decision lives in the model, not the view.
class ModulationPostComponent < ApplicationComponent
  attr_reader :post, :viewer, :query

  BUCKET_ORDER = %i[creator both auto pending].freeze

  def initialize(post:, viewer:, query: nil)
    super
    @post = post
    @viewer = viewer
    @query = query
  end

  # --- gallery navigation -------------------------------------------------
  # The sort presets offered for this post. "Defaults always travel with the
  # user" (prime directive): #, date, and -- when the post has one -- a same-
  # artist gallery. Each preset is a search string; PostNeighbors resolves its
  # true prev/next. Custom saved sorts merge on top of these later.
  def nav_presets
    @nav_presets ||= build_nav_presets
  end

  # The preset matching the sort the viewer arrived with (default: by number).
  def active_preset_key
    @active_preset_key ||= (nav_presets.find { _1[:active] } || nav_presets.first)&.fetch(:key)
  end

  # ------------------------------------------------------------------------

  # { creator:, auto:, both:, meta:, pending: } -- creator already privacy-gated.
  def buckets
    @buckets ||= FourierTagSource.for_viewer(post, viewer)
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
      "#{post.image_width}×#{post.image_height}",
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
  # the denormalised string still holds the private creator tags.
  def blacklist_data
    {
      "data-id" => post.id,
      "data-tags" => blacklist_tags.join(" "),
      "data-rating" => post.rating,
      "data-flags" => post.status_flags,
      "data-score" => post.score,
      "data-uploader-id" => post.uploader_id,
    }
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for([post], viewer).fetch(post, [])
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
      vote: (vote.nil? ? nil : (vote.is_positive? ? "up" : "down")),
      vote_id: vote&.id,
      can_vote: !anonymous?,
    }
  end

  def fav_payload
    { count: post.fav_count, faved: post.favorited_by?(viewer), can_fav: !anonymous? }
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

    case status
    when "banned"
      list << { kind: "banned", text: "This post was removed following a takedown request or rule violation." }
    when "deleted"
      list << { kind: "deleted", text: "This post was deleted." }
    when "pending"
      list << { kind: "pending", text: "This post is pending approval." }
    when "flagged"
      list << { kind: "pending", text: "This post was flagged and is pending approval." }
    when "appealed"
      list << { kind: "pending", text: "This post was appealed and is pending approval." }
    end

    if post.parent_id.present?
      list << {
        kind: "parent",
        text: "This post belongs to a parent.",
        href: routes.post_path(post.parent_id, preset: "modulation"),
        label: "view parent ##{post.parent_id}",
      }
    end

    if post.has_visible_children?
      list << {
        kind: "child",
        text: "This post has children.",
        href: routes.posts_path(tags: "parent:#{post.id}", preset: "modulation"),
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
      # These route to the upstream page because Modulation has no native form
      # for them yet. preset_sticky: 0 is what keeps that a detour rather than
      # a one-way door -- the viewer edits and comes back, instead of silently
      # spending the rest of their session in the old interface.
      edit_href = routes.post_path(post, preset: "historical", preset_sticky: 0, anchor: "edit")
      groups << { label: "contribute", links: [
        { label: "Edit tags", href: edit_href },
        { label: "Add to pool", href: edit_href },
        { label: "Add commentary", href: edit_href },
      ] }
    end

    report = []
    report << { label: "Flag", href: routes.new_post_flag_path(post_flag: { post_id: post.id }) } if post.is_active?
    report << { label: "Appeal", href: routes.new_post_appeal_path(post_appeal: { post_id: post.id }) } if post.is_appealable?
    groups << { label: "report", links: report } if report.any?

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
  def payload
    {
      id: post.id,
      url: post_url_for(post, query.presence),
      media: media_payload,
      meta: meta_payload,
      gated: media_gated?,
      tags: buckets,
      presets: nav_presets.map { |p| p.slice(:key, :label, :search, :prev, :next) },
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
    }
  end

  # Rails' route helpers, for the payload builders above. Kept as one reader so
  # the "context-free, no view helpers" contract stays easy to see.
  def routes
    Rails.application.routes.url_helpers
  end

  private

  def media_payload
    visible = post.visible?(viewer)
    if post.is_image?
      { kind: "image", src: (visible ? post.large_file_url : nil), full: (visible ? post.tagged_file_url : nil), w: post.image_width, h: post.image_height }
    elsif post.is_video?
      { kind: "video", src: (visible ? post.file_url : nil), poster: (visible ? post.preview_file_url : nil), w: post.image_width, h: post.image_height }
    else
      # ugoira / flash / other: Modulation shows the preview + a link out.
      { kind: "other", src: (visible ? post.preview_file_url : nil), href: post_url_for(post, nil), w: post.image_width, h: post.image_height }
    end
  rescue StandardError
    { kind: "other", src: nil, href: post_url_for(post, nil) }
  end

  def meta_payload
    fields = metadata_fields.map { |text| { text: text } }
    fields << { text: "source", href: post.normalized_source } if post.source.present? && post.normalized_source.present?
    # Rating rides in the metadata line rather than the action row: it is a
    # property of the post, not something you do to it. Status only appears when
    # it is not "active" -- a badge that is always there stops being read.
    fields << { text: "rating:#{post.rating}" }
    fields << { text: status, status: true } unless status == "active"
    fields
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
    # No neighbours for a restricted viewer: the sorts and the flank previews
    # ARE the browsing this tier does not have. Withholding them here rather
    # than letting the links 410 means the restriction reads as a boundary
    # instead of as a broken page.
    return [] unless can_browse?

    incoming_order = PostQuery.new(query.to_s).find_metatag(:order).presence&.downcase

    defs = []
    # "via tag search" -- the exact search the viewer arrived with (tags + its
    # own order). This is the primary sort when you enter from a gallery search;
    # it leads the preset list and is active by default.
    if base_tags.present?
      defs << { key: "search", label: "search", search: [base_tags, ("order:#{incoming_order}" if incoming_order)].compact.join(" ").squish }
    end
    defs += [
      { key: "num",  label: "#",    search: with_order(base_tags, "id_desc") },
      { key: "date", label: "date", search: with_order(base_tags, "created_at") },
    ]
    if artist_names.any?
      # Dedupe so navigating within the artist gallery (which carries the artist
      # in q) doesn't double the tag and trip the search's tag limit.
      artist_search = (base_tags.split + [artist_names.first]).uniq.join(" ")
      defs << { key: "artist", label: "artist", search: with_order(artist_search, "id_desc") }
    end

    current_order = incoming_order || "id_desc"
    resolved = defs.map do |d|
      # A preset whose query can't run (e.g. exceeds the viewer's tag limit) must
      # degrade to "no neighbours", never 500 the whole view.
      nav = PostNeighbors.new(post: post, tags: d[:search], user: viewer)
      d.merge(prev_id: nav.prev_id, next_id: nav.next_id, order: nav.order)
    rescue StandardError
      d.merge(prev_id: nil, next_id: nil, order: (PostQuery.new(d[:search]).find_metatag(:order).presence || "id_desc").downcase)
    end

    # One batched load for every neighbour thumbnail, not a query per preview.
    ids = resolved.flat_map { [_1[:prev_id], _1[:next_id]] }.compact.uniq
    posts_by_id = Post.where(id: ids).includes(:media_asset).index_by(&:id)

    resolved.map do |d|
      d.merge(
        active: d[:order] == current_order,
        prev: neighbour_preview(posts_by_id[d[:prev_id]], d[:search]),
        next: neighbour_preview(posts_by_id[d[:next_id]], d[:search]),
      )
    end
  end

  def neighbour_preview(neighbour, search)
    return nil if neighbour.nil?

    { id: neighbour.id,
      url: post_url_for(neighbour, search),
      thumb: (neighbour.visible?(viewer) ? neighbour.preview_file_url : nil) }
  rescue StandardError
    nil
  end

  # Route helper that works outside a render context (used by the JSON endpoint).
  def post_url_for(target, search)
    Rails.application.routes.url_helpers.post_path(target, preset: "modulation", q: search.presence)
  end
end
