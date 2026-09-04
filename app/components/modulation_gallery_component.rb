# frozen_string_literal: true

# "Modulation" gallery -- the post index in the Modulation theme. Same visual
# language as the post view (dark, token-driven, colour-coded tag pills with a
# unitag/grouped toggle); here the tags are the search's facet tags and the
# grouping dimension is tag CATEGORY rather than provenance.
#
# Tag search is the primary control ("sort by via tag search"). Thumbnails link
# into the Modulation post view carrying the current search as navigation
# context, so the post view's "search" preset picks up exactly where the gallery
# left off.
class ModulationGalleryComponent < ApplicationComponent
  attr_reader :post_set, :viewer

  # Display order for the category buckets.
  CATEGORY_ORDER = %w[artist copyright character general meta].freeze

  # `settings` is the viewer's Modulation view state (ModulationSetting.for_viewer);
  # the panel renders its remembered sort, view and deleted toggle from it.
  def initialize(post_set:, viewer:, settings: nil)
    super
    @post_set = post_set
    @viewer = viewer
    @settings = settings || ModulationSetting.defaults
  end

  attr_reader :settings

  # The sort the panel is set to: the query's own order (the panel memory has
  # already been woven in by the controller), falling back to the remembered
  # one so the select never shows blank while a memory is in force.
  def active_sort
    @active_sort ||= post_set.post_query.find_metatag(:order).presence&.downcase || settings["gallery_sort"]
  end

  def initial_view
    ModulationSetting::GALLERY_VIEWS.include?(settings["gallery_view"]) ? settings["gallery_view"] : "unitag"
  end

  def show_deleted_remembered?
    !!settings["gallery_show_deleted"]
  end

  # The current query with status: stripped, for the deleted toggle: the
  # toggle must not carry the very metatag it is about to change back in.
  def query_without_status
    query_string.gsub(/(?:\A|\s)-?status:\S+/i, " ").squish
  end

  # The posts this gallery will actually draw.
  #
  # Deleted posts are dropped unless the viewer has asked for them, which is
  # upstream's rule -- PostPreviewComponent#render? refuses to draw a deleted
  # post unless show_deleted -- and it was lost when this gallery replaced that
  # component. So on this fork a deleted post rendered in the default gallery,
  # which is the one place upstream is careful to keep it out of.
  #
  # Worth naming, because the shape recurs: a fork that reimplements an upstream
  # view inherits its LAYOUT and silently drops its GUARDS. The blacklist went
  # the same way in this same component.
  #
  # Note the inconsistency this preserves rather than fixes: post_set counts
  # deleted posts and this does not, so a page can report more results than it
  # draws. That is upstream's behaviour too, and correcting it belongs in a
  # change about pagination rather than one about a missing guard.
  def posts
    return post_set.posts if show_deleted?

    post_set.posts.reject(&:is_deleted?)
  end

  delegate :show_deleted?, to: :post_set

  def query_string
    post_set.tag_string.to_s.strip
  end

  # The post view link, carrying the search so its nav follows this exact search.
  def post_link(post)
    routes.post_path(post, preset: "modulation", q: query_string.presence)
  end

  # The facet tags this viewer may be shown: banished names withheld unless
  # the admin reveal toggle is on. See TagBanishment.
  def visible_sidebar_tags
    @visible_sidebar_tags ||= begin
      tags = post_set.sidebar_tags
      TagBanishment.revealed_to?(viewer) ? tags : tags.reject { |t| TagBanishment.banished?(t.name) }
    end
  end

  # Facet tags grouped by category, in display order: [[key, [tags]], ...].
  def tag_groups
    grouped = visible_sidebar_tags.group_by { |t| category_key(t) }
    CATEGORY_ORDER.filter_map { |k| [k, grouped[k]] if grouped[k].present? }
  end

  # Flat unitag list: [[tag, category_key], ...] in the same category order.
  def unitag_list
    tag_groups.flat_map { |key, tags| tags.map { |t| [t, key] } }
  end

  def any_tags?
    visible_sidebar_tags.any?
  end

  # Blacklist rules are matched client-side against these attributes, so every
  # card has to carry them or the viewer's blacklist silently does not apply --
  # which is what happened for as long as this gallery rendered bare <a> cards
  # and the blacklist's selector list knew nothing about them.
  #
  # data-tags comes from FourierTagSource.blacklist_tags_for, NOT post.tag_string:
  # tag_string still holds the private creator tags, and this is the default view
  # of the site.
  def card_data(post)
    {
      "data-id" => post.id,
      "data-tags" => blacklist_tags[post].to_a.join(" "),
      "data-rating" => post.rating,
      "data-flags" => post.status_flags,
      "data-score" => post.score,
      "data-uploader-id" => post.uploader_id,
    }
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for(posts, viewer)
  end

  def thumb_for(post)
    post.visible?(viewer) ? post.preview_file_url : nil
  rescue StandardError
    nil
  end

  def current_page
    [post_set.current_page.to_i, 1].max
  end

  # --- parity with the upstream index -------------------------------------
  # The upstream page keeps these in sidebar sections this gallery hides. They
  # are search-scoped navigation, so they belong with the search controls rather
  # than as a transplanted sidebar.

  delegate :post_count, to: :post_set

  def total_pages
    count = post_count
    return nil if count.nil? || post_set.per_page.to_i <= 0

    [(count.to_f / post_set.per_page).ceil, 1].max
  end

  # "Related": the same search seen another way. Deliberately only the ones that
  # act on the CURRENT query -- the upstream list mixes those with global
  # discovery links, and mixing them is why that section reads as a junk drawer.
  def related_links
    # "deleted" is a remembered TOGGLE, not a one-off search: on, the panel
    # keeps including deleted posts (status:any) in every search until it is
    # clicked off (operator ruling 2026-09-04 -- the panel does not reset).
    links = [
      { label: "random", href: routes.random_posts_path(tags: query_string.presence, preset: "modulation") },
      { label: "deleted", href: routes.posts_path(tags: query_without_status.presence, preset: "modulation", show_deleted: (show_deleted_remembered? ? 0 : 1)), active: show_deleted_remembered? },
      { label: "count", href: routes.posts_counts_path(tags: query_string.presence) },
    ]

    if single_tag.present?
      links << { label: "history", href: routes.post_versions_path(search: { changed_tags: single_tag }) }
      links << { label: "discussions", href: routes.forum_posts_path(search: { linked_to: single_tag }) } if forum_enabled?
    end

    links
  end

  def forum_enabled?
    Danbooru.config.forum_enabled?.to_s.truthy?
  end

  def single_tag
    return nil unless post_set.post_query.has_single_tag?

    post_set.post_query.tag_name
  end

  def can_save_search?
    # Not ApplicationComponent#policy: that delegates to a current_user method
    # this component does not have -- it takes its viewer explicitly, because it
    # is also built outside a request in the navigation payload path.
    SavedSearchPolicy.new(viewer, SavedSearch).create?
  end

  # The excerpt: when a search IS a subject -- one tag with a wiki page, an
  # artist entry, or a pool -- upstream offers its summary behind a tab. Search
  # for a character and the page can say who they are; without it the search is
  # a wall of thumbnails with no answer to "what am I looking at".
  def excerpt
    if post_set.artist.present? && !post_set.artist.is_banned?
      @excerpt ||= { kind: "artist", title: post_set.artist.name.tr("_", " "), href: routes.artist_path(post_set.artist), body: post_set.artist.wiki_page&.body }
    elsif post_set.pool.present?
      @excerpt ||= { kind: "pool", title: post_set.pool.pretty_name, href: routes.pool_path(post_set.pool), body: post_set.pool.description }
    elsif post_set.wiki_page.present?
      @excerpt ||= { kind: "wiki", title: post_set.wiki_page.pretty_title, href: routes.wiki_page_path(post_set.wiki_page), body: post_set.wiki_page.body }
    end
  end

  # A summary, not the article: the wiki page is one click away and a long entry
  # would push the posts off the screen the viewer came for.
  def excerpt_summary
    body = excerpt&.dig(:body).to_s.strip
    return nil if body.blank?

    # DText bodies are stored with CRLF, so a bare /\n{2,}/ never splits and the
    # whole article comes through as one "first paragraph".
    first = body.split(/(?:\r?\n){2,}/).first.to_s.squish
    (first.length > 320) ? "#{first[0, 317]}..." : first
  end

  def can_browse?
    viewer.present? && viewer.can_browse_freely?
  end

  def more_pages?
    # A restricted viewer gets one page, so there is no next to offer. Not
    # rendering the link is the point: a "next" that 410s is a bug-shaped way to
    # express a policy.
    can_browse? && posts.size >= post_set.per_page
  end

  # Shown when there are more results than this viewer is allowed to page
  # through, so the cut-off is explained where it happens rather than being
  # discovered as a missing button.
  def truncated?
    return false if can_browse?

    post_count.to_i > posts.size
  end

  def page_url(page)
    routes.posts_path(preset: "modulation", tags: query_string.presence, page: (page if page > 1))
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  def category_key(tag)
    return "artist" if tag.artist?
    return "copyright" if tag.copyright?
    return "character" if tag.character?
    return "meta" if tag.meta?

    "general"
  end
end
