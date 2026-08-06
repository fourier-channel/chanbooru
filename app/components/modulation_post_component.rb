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
    }
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

  def build_nav_presets
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
