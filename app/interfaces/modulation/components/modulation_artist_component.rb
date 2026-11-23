# frozen_string_literal: true

# Modulation's artist page (artists/show and artists/show_or_new): the subject
# heading, the entry's names, wiki, URLs and relationships as panels, the
# creator release box, and the artist's posts as a strip of the gallery's
# cards.
#
# It draws and decides nothing. Every condition in the template is upstream's,
# copied verbatim with the file and line it mirrors:
#   app/views/artists/show.html.erb     (the takedown gate, the release box,
#                                        the posts)
#   app/views/artists/_summary.html.erb (the heading, the new-record line,
#                                        names, wiki, URLs, edit links,
#                                        relationships)
# _summary is not rendered here because its markup is the page being redrawn,
# so A CHANGE TO EITHER UPSTREAM FILE DOES NOT REACH THIS PAGE BY ITSELF:
# re-read both on every upstream pull and carry any changed condition here.
#
# The viewer is the request's CurrentUser.user, which is also the controller's
# pundit_user (ApplicationController#pundit_user), so policy() here asks the
# same policy object upstream's view asks.
class ModulationArtistComponent < ApplicationComponent
  attr_reader :artist, :viewer

  # @param artist [Artist] the entry (a new record on show_or_new)
  # @param viewer [User] CurrentUser.user
  def initialize(artist:, viewer:)
    super
    @artist = artist
    @viewer = viewer
  end

  # ApplicationComponent#policy asks Pundit for current_user.
  def current_user
    viewer
  end

  # app/views/artists/show.html.erb:7 (and _summary.html.erb:17).
  def taken_down?
    artist.is_banned? && !policy(artist).can_view_banned?
  end

  # app/views/artists/_summary.html.erb:4 and :8, in upstream's order.
  def badges
    [("BANNED" if artist.is_banned?), ("DELETED" if artist.is_deleted?)].compact
  end

  # app/views/artists/_summary.html.erb:48.
  def show_wiki?
    artist.wiki_page.present? && !artist.wiki_page.is_deleted?
  end

  # The names block of _summary.html.erb:22-46 draws only these three; the
  # panel is left out when none is present, as upstream's block is then empty.
  def names?
    artist.other_names.present? || artist.group_name.present? || artist.members.present?
  end

  # app/views/artists/show.html.erb:30.
  def show_posts?
    artist.tag.present? && artist.tag.post_count > 0
  end

  # app/views/artists/show.html.erb:37: the exact relation upstream's gallery
  # renders (render_post_gallery(..., tags: @artist.name), no show_deleted),
  # filtered by PostPreviewComponent.drawable? in PostStripSurface.
  def post_strip
    @post_strip ||= PostStripSurface.new(
      relation: PostQuery.normalize(artist.name, current_user: viewer, default_order: PostQuery::LISTING_DEFAULT_ORDER).with_implicit_metatags.posts_with_timeout(8),
      viewer: viewer,
      query: artist.name,
    )
  end
end
