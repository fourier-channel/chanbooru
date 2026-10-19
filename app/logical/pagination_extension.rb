# frozen_string_literal: true

# A mixin that adds a `#paginate` method to an ActiveRecord relation.
#
# There are two pagination techniques. The first is page-based (numbered):
#
#   https://danbooru.donmai.us/posts?page=1
#   https://danbooru.donmai.us/posts?page=2
#   https://danbooru.donmai.us/posts?page=3
#
# The second is id-based (sequential):
#
#   https://danbooru.donmai.us/posts?page=a1000&limit=100
#   https://danbooru.donmai.us/posts?page=a1100&limit=100
#   https://danbooru.donmai.us/posts?page=a1200&limit=100
#
#   https://danbooru.donmai.us/posts?page=b1000&limit=100
#   https://danbooru.donmai.us/posts?page=b900&limit=100
#   https://danbooru.donmai.us/posts?page=b800&limit=100
#
# where a1000 means "after id 1000" and b1000 means "before id 1000".
#
# Fork: a third, the Modulation gallery window's (seek:), pages from a
# PostNeighbors::Seek -- a cursor in any sort, not only by id -- one chunk at
# a time, forward from an anchor or backward before one. It takes no page
# number: `page` is ignored when a seek is given.
#
# Fork: THE BROWSING TIER IS ENFORCED HERE (ACCOUNT_LIMITS.md 2.1), at the
# one place every list passes through -- posts, and tags, users, wiki pages,
# artists and the rest (operator, 2026-10-18: "every listing"). For a viewer
# below full browsing (User#can_browse_freely?) a list is one page of at most
# User#listing_per_page_limit records: page 2, any a/b cursor, and a seek that
# names a place are refused (BrowsingCapError, 410). Nothing here knows which
# model it pages, so a list added later is bounded without knowing. The one
# way past is by name, from TIER_EXEMPT.
module PaginationExtension
  class PaginationError < StandardError; end

  # The tier's refusal: a page, a cursor or a walk past what a viewer below
  # full browsing gets. A PaginationError, so it answers 410.
  class BrowsingCapError < PaginationError
    def initialize(viewer)
      super("This account sees one page of each list, #{viewer.listing_per_page_limit} at most, with no next or previous. " \
            "Fix: a full account browses further; ask staff for one.")
    end
  end

  # A surface that is not bounded by the tier, by name and with the reason
  # (the pattern of MembersOnly::ANONYMOUS_DOORS): bounded unless it opts out
  # here. An unknown name raises.
  TIER_EXEMPT = {
    hero_band: "operator 2026-10-08: the anonymous draw; its scope is the enabled rows the operator chose (a834a630f)",
  }.freeze

  # A cursor page: after or before an id.
  CURSOR = /\A[ab]\d+\z/i

  attr_accessor :current_page, :records_per_page, :paginator_count, :paginator_mode, :paginator_page_limit, :paginator_seek, :paginator_cursors

  # Paginate an ActiveRecord relation. Returns a relation for the given page and number of posts per page.
  #
  # @param page [String] the page number, or an "aNNN" or "bNNN" string
  # @param limit [Integer] the number of posts per page
  # @param max_limit [Integer] the most records per page this surface serves (the viewer's own ceiling applies too)
  # @param page_limit [Integer] the highest page this surface serves (default: the viewer's)
  # @param count [Integer] the precalculated number of search results, or nil to calculate it
  # @param search_count [Object] if truthy, don't calculate the number of results; assume a large number of results
  # @param seek [PostNeighbors::Seek, nil] page from this cursor instead (the gallery window)
  # @param viewer [User] whose limits apply: pass it wherever CurrentUser is not the viewer
  # @param tier_exempt [Symbol, nil] a TIER_EXEMPT key
  def paginate(page, limit: nil, max_limit: User::MAX_PER_PAGE, page_limit: nil, count: nil, search_count: nil, seek: nil, viewer: CurrentUser.user, tier_exempt: nil) # rubocop:disable Metrics/ParameterLists
    raise ArgumentError, "paginate has no viewer: CurrentUser is unset outside a request. Fix: pass viewer:." if viewer.nil?
    raise ArgumentError, "#{tier_exempt.inspect} is not a TIER_EXEMPT key. Fix: add it to PaginationExtension::TIER_EXEMPT with its reason, or drop tier_exempt:." if tier_exempt && !TIER_EXEMPT.key?(tier_exempt)

    capped = tier_exempt.nil? && !viewer.can_browse_freely?
    page_limit ||= viewer.page_limit
    page_limit = [page_limit, viewer.listing_page_limit].min if capped
    max_limit = [max_limit, tier_exempt ? User::MAX_PER_PAGE : viewer.listing_per_page_limit].min

    @records_per_page = limit || Danbooru.config.posts_per_page
    @records_per_page = @records_per_page.to_i.clamp(1, max_limit)
    @paginator_page_limit = page_limit
    @paginator_cursors = !capped

    if count.present?
      @paginator_count = count
    elsif !search_count.nil? && search_count.blank?
      @paginator_count = Float::INFINITY
    end

    raise BrowsingCapError, viewer if capped && (page.to_s.match?(CURSOR) || seek&.place? || page.to_i > page_limit)

    if seek
      paginate_seek(seek, records_per_page, page_limit)
    elsif page.to_s =~ /\Ab(\d+)\z/i
      @paginator_mode = :sequential_before
      paginate_sequential_before($1, records_per_page)
    elsif page.to_s =~ /\Aa(\d+)\z/i
      @paginator_mode = :sequential_after
      paginate_sequential_after($1, records_per_page)
    elsif page.to_i > page_limit
      raise PaginationError, "You cannot go beyond page #{page_limit}."
    else
      # The last page a viewer may reach is numbered like every other: it
      # once switched to sequential_after here while building numbered SQL,
      # and #records reversed it (ACCOUNT_LIMITS.md 2.0). #next_page goes on
      # from it by cursor, for a viewer who may use one.
      @paginator_mode = :numbered
      @current_page = [page.to_i, 1].max

      paginate_numbered(current_page, records_per_page)
    end
  end

  def paginate_sequential_before(before_id, limit)
    where("#{table_name}.id < ?", before_id).reorder("#{table_name}.id DESC").limit(limit + 1)
  end

  def paginate_sequential_after(after_id, limit)
    where("#{table_name}.id > ?", after_id).reorder("#{table_name}.id ASC").limit(limit + 1)
  end

  def paginate_numbered(page, limit)
    offset((page - 1) * limit).limit(limit)
  end

  # A position is an OFFSET, which is what the page limit bounds: counted in
  # pages of the default size, the same reach a numbered page had.
  def paginate_seek(seek, limit, page_limit)
    reach = page_limit * Danbooru.config.posts_per_page.to_i
    if seek.offset && seek.offset > reach
      raise PaginationError, "You cannot go past result #{reach} in a position-based sort. Pick newest, oldest, score, favorites or date to go further."
    end

    @paginator_seek = seek
    @paginator_mode = seek.backward? ? :seek_backward : :seek_forward
    seek.page(self, limit)
  end

  # Whether the search goes on past this chunk, in the chunk's direction.
  def more?
    load
    paginator_seek.more?(@records.size, records_per_page)
  end

  def is_first_page?
    case paginator_mode
    when :numbered
      current_page == 1
    when :sequential_before
      false
    when :sequential_after
      load
      @records.size <= records_per_page
    end
  end

  def is_last_page?
    case paginator_mode
    when :numbered
      current_page >= total_pages
    when :sequential_before
      load
      @records.size <= records_per_page
    when :sequential_after
      false
    end
  end

  def prev_page
    if is_first_page?
      nil
    elsif paginator_mode == :numbered
      current_page - 1
    elsif records.present?
      "a#{records.first.id}"
    else
      nil
    end
  rescue ActiveRecord::QueryCanceled
    nil
  end

  def next_page
    if is_last_page?
      nil
    elsif paginator_mode == :numbered && current_page < paginator_page_limit
      current_page + 1
    elsif paginator_mode == :numbered
      "b#{records.last.id}" if paginator_cursors && records.present?
    elsif records.present?
      "b#{records.last.id}"
    else
      nil
    end
  rescue ActiveRecord::QueryCanceled
    nil
  end

  # XXX Hack: in sequential pagination we fetch one more record than we
  # need so that we can tell when we're on the first or last page. Here
  # we override a rails internal method to discard that extra record. See
  # #2044, #3642.
  def records
    case paginator_mode
    when :sequential_before
      super.first(records_per_page)
    when :sequential_after
      super.first(records_per_page).reverse
    when :seek_forward
      super.first(records_per_page)
    when :seek_backward
      paginator_seek.reversed? ? super.first(records_per_page).reverse : super
    when :numbered
      super
    end
  end

  # Return the number of pages of results, or infinity if it takes too long to count.
  def total_pages
    return Float::INFINITY if total_count.infinite?
    (total_count.to_f / records_per_page).ceil
  end

  # Return the number of results, or infinity if it takes too long to count.
  def total_count
    @paginator_count ||= unscoped.from(except(:offset, :limit, :order).reorder(nil)).count
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.to_s =~ /statement timeout/
    @paginator_count ||= Float::INFINITY
  end
end
