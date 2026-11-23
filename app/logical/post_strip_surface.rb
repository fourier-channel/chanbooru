# frozen_string_literal: true

# A short run of post cards on a drawn page -- an artist's or a wiki page's
# posts, the popular page -- decided once in core for the viewer it is handed,
# as GallerySurface decides the post index. It draws the cards PostCards
# decides (link, blacklist projection, provenance marks, thumbnail or gated
# face, artist credit) for exactly the posts upstream's gallery would draw:
# PostPreviewComponent.drawable?, the one predicate for "does this post exist
# for this viewer in a list" -- visible, not deleted unless asked, not
# banished, not hidden beyond deletion. A card is never drawn gated for a
# post upstream omits, which would leak its id and its existence.
#
# The caller passes the EXACT relation upstream's view renders, e.g.
#   PostQuery.normalize(name, current_user: viewer, default_order: PostQuery::LISTING_DEFAULT_ORDER)
#     .with_implicit_metatags.posts_with_timeout(8)
# (the default order the listing a strip links to uses)
# never a PostSets::Post: its posts pages with a COUNT and changes the
# timeout and the limit. This surface adds no query of its own beyond the
# card data's batched plucks, and never counts.
class PostStripSurface
  include PostCards

  attr_reader :viewer, :query_string

  # @param relation [ActiveRecord::Relation, Array<Post>] the posts, as
  #   upstream's view builds them for this page
  # @param viewer [User] whom every decision is made for
  # @param query [String, nil] the search a card's post link carries
  # @param show_deleted [Boolean] upstream's show_deleted, for a list that asks
  def initialize(relation:, viewer:, query:, show_deleted: false)
    @relation = relation
    @viewer = viewer
    @query_string = query.to_s.strip
    @show_deleted = show_deleted
  end

  # The posts this viewer is drawn, in the relation's order.
  def posts
    @posts ||= loaded.select { |post| PostPreviewComponent.drawable?(post, viewer, show_deleted: @show_deleted) }
  end

  delegate :empty?, to: :posts

  private

  # One media-asset load for the run, as render_post_gallery does for a
  # relation; an array (posts_with_timeout's answer) is preloaded in place.
  def loaded
    if @relation.is_a?(ActiveRecord::Relation)
      @relation.includes(:media_asset).to_a
    else
      records = @relation.to_a
      ActiveRecord::Associations::Preloader.new(records: records, associations: :media_asset).call
      records
    end
  end
end
