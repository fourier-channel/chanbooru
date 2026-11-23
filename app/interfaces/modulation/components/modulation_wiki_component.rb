# frozen_string_literal: true

# Modulation's wiki page (wiki_pages/show): the page as a subject heading, the
# article in the one panel, and the tag's posts as a strip of the gallery's
# cards. It draws upstream's page (app/views/wiki_pages/show.html.erb) and
# decides nothing: every condition below is upstream's, on the same object,
# with the upstream line it mirrors named beside it. The head tags, the
# secondary links and the sidebar stay in the view, as upstream writes them.
#
# Upstream partials are rendered, not copied: wiki_pages/_original_character
# and tag_relationships/_alias_and_implication_list. The tag change notice is
# the render_tag_change_notice helper, so the cache it holds stays in core and
# never sits in interface text.
#
# The post strip replaces wiki_pages/_posts: the same condition, the EXACT
# relation it renders, and PostStripSurface's filter, which is the predicate
# upstream's gallery draws by (PostPreviewComponent.drawable?).
class ModulationWikiComponent < ApplicationComponent
  attr_reader :wiki_page, :viewer

  # ApplicationComponent#policy asks Pundit for current_user: the viewer, as
  # upstream's view asks for CurrentUser.user (ApplicationController#pundit_user).
  alias_method :current_user, :viewer

  # @param wiki_page [WikiPage] the page, as the controller found or built it
  # @param viewer [User] whom the page is drawn for (CurrentUser.user)
  def initialize(wiki_page:, viewer:)
    super
    @wiki_page = wiki_page
    @viewer = viewer
  end

  # The heading's state chips. Upstream: wiki_pages/show.html.erb:16-22,
  # "(locked)" and "(deleted)".
  def badges
    [("locked" if wiki_page.is_locked?), ("deleted" if wiki_page.is_deleted?)]
  end

  # The pill's paint: upstream colours the title link by tag_class(@wiki_page.tag)
  # (wiki_pages/show.html.erb:14); PostCards.category_key is the one mapping.
  def category_key
    PostCards.category_key(wiki_page.tag)
  end

  # The same count upstream's secondary links show beside "Posts"
  # (wiki_pages/_secondary_links.html.erb:11,14); none without a tag.
  def post_count
    wiki_page.tag&.post_count
  end

  # Upstream: wiki_pages/_posts.html.erb:1.
  def show_posts?
    wiki_page.tag.present? && !wiki_page.tag.empty?
  end

  # The relation wiki_pages/_posts.html.erb:8 renders, exactly; the card links
  # carry the title, as its `tags: wiki_page.title` does.
  def strip_surface
    @strip_surface ||= PostStripSurface.new(
      relation: PostQuery.normalize(wiki_page.tag.name, current_user: viewer, default_order: PostQuery::LISTING_DEFAULT_ORDER).with_implicit_metatags.posts_with_timeout(8),
      viewer: viewer,
      query: wiki_page.title,
    )
  end
end
