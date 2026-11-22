# frozen_string_literal: true

# A post card, decided once in core for every surface that draws one: the
# post index's gallery (GallerySurface) and a drawn page's post strip
# (PostStripSurface). The card's link, its data attributes -- the viewer's
# own blacklist projection, the public provenance marks -- its thumbnail or
# gated face, its artist credit and the page's tag maps all come from here,
# so a card on an artist or wiki page blacklists, gates and credits exactly
# as one on /posts does. Lifted verbatim from GallerySurface (Modulation
# families, Unit 0); the comments are the ones the gallery carried.
#
# The including class supplies:
#   posts        -- the posts this surface draws, already decided for the viewer
#   viewer       -- the User every decision is made for (never CurrentUser)
#   query_string -- the search a card's post link carries, or ""
module PostCards
  # The blacklist engine's markers (Blacklist.POST_SELECTOR in blacklists.js),
  # owned here in core so the engine and its pre-hide never name an
  # interface's card class. Every card an interface draws carries
  # BLACKLIST_POST: matched, counted, and hidden until the engine has run
  # (blocklist_component.scss). A pool a surface draws FROM rather than shows
  # -- the Modulation post view's flank candidates -- carries
  # BLACKLIST_UNCOUNTED: matched and marked, left out of the counts. The
  # privacy test fails on a drawn post the engine does not match.
  BLACKLIST_POST = "blacklist-post"
  BLACKLIST_UNCOUNTED = "blacklist-uncounted"

  # A tag's category as the pill and the hover panel name it. One mapping for
  # every surface; a view never re-derives it. nil for no tag.
  def self.category_key(tag)
    return nil if tag.nil?
    return "artist" if tag.artist?
    return "copyright" if tag.copyright?
    return "character" if tag.character?
    return "meta" if tag.meta?

    "general"
  end

  # The post view link, carrying the search so its nav follows this exact search.
  def post_link(post)
    routes.post_path(post, q: query_string.presence)
  end

  # Blacklist rules are matched client-side against these attributes, so every
  # card has to carry them or the viewer's blacklist silently does not apply --
  # which is what happened for as long as this gallery rendered bare <a> cards
  # and the blacklist's selector list knew nothing about them.
  #
  # data-tags comes from FourierTagSource.blacklist_tags_for, NOT post.tag_string:
  # the post's creator also sees their private tags, which tag_string does not
  # carry, and a quarantined name stays out of the page.
  #
  # GallerySurface adds data-key, the card's place in its search, after
  # data-id; a strip has no window and no key.
  def card_data(post)
    {
      "data-id" => post.id,
      "data-tags" => blacklist_tags[post].to_a.join(" "),
      "data-rating" => post.rating,
      "data-flags" => post.status_flags,
      "data-score" => post.score,
      "data-uploader-id" => post.uploader_id,
      "data-tag-marks" => card_tag_marks.fetch(post.id, {}).to_json,
    }
  end

  # Each card's tags, for the hover panel: name -> [bucket, lamp], the same
  # two answers the facet pills get, per post rather than per page. Public
  # rows, one pluck for the page. A tag with no row is left out -- the panel
  # draws it unsourced with a white lamp, which is what no row means.
  #
  # Fork: only rows for a tag the card carries (card_tags). A row stays
  # behind when its tag leaves the post -- a hand edit, a bulk update and the
  # private-tag cleanup write tag_string, never the sidecar -- and such a
  # dormant row is provenance for nothing here; its name was written into
  # the page source all the same (BUR review 2026-10-19).
  #
  # Fork: a "both" row (CREATOR | AUTO) is public and says "both" on every
  # card, to every viewer: its colouring says the model agrees with what the
  # creator asked for (operator, 2026-10-19). Only a creator-ONLY row is
  # private, and publicly_visible already leaves it out.
  def card_tag_marks
    @card_tag_marks ||= FourierTagSource.publicly_visible
      .where(post_id: posts.map(&:id))
      .pluck(:post_id, :tag, :source, :status)
      .select { |post_id, tag, _, _| card_tags.fetch(post_id, Set.new).include?(tag) }
      .group_by(&:first)
      .transform_values do |rows|
        rows.to_h { |_, tag, source, status| [tag, [provenance_bucket(source, status == FourierTagSource::PENDING), FourierTagSource.lamp_of(source).to_s]] }
      end
  end

  def blacklist_tags
    @blacklist_tags ||= FourierTagSource.blacklist_tags_for(posts, viewer)
  end

  # Fork: post id -> the Set of tags its card carries (data-tags), which a
  # provenance row must name to count for that card.
  def card_tags
    @card_tags ||= posts.to_h { |post| [post.id, blacklist_tags[post].to_a.to_set] }
  end

  # The card's thumbnail, or nil for a gated card. Fails closed: a post whose
  # visibility or preview cannot be decided draws as gated, and says so in
  # the log, where it was once dropped without a word.
  def thumb_for(post)
    post.visible?(viewer) ? post.preview_file_url : nil
  rescue StandardError => e
    Rails.logger.error("#{self.class.name}#thumb_for: post ##{post.id} drew as gated for #{viewer&.id ? "user ##{viewer.id}" : "a signed-out viewer"}: " \
                       "#{e.class}: #{e.message} (#{e.backtrace&.first}); fix: repair what raised -- Post#visible? or " \
                       "the post's media asset (preview_file_url) -- and the card draws its thumbnail again")
    nil
  end

  # name -> category key for every tag on this page's cards, one batched
  # lookup (Tag.categories_for is a memcache multi-get -- never per-card).
  # Built from the same gated projection as data-tags, then banished names
  # are withheld: the map doubles as the hover panel's DISPLAY gate, so the
  # client shows only tags it can find here and never learns the banished
  # vocabulary at all.
  def page_tag_categories
    @page_tag_categories ||= begin
      names = TagBanishment.filter(blacklist_tags.values.flatten.uniq, viewer)
      ints = Tag.categories_for(names)
      keys = {
        TagCategory::ARTIST => "artist",
        TagCategory::COPYRIGHT => "copyright",
        TagCategory::CHARACTER => "character",
        TagCategory::META => "meta",
      }
      names.index_with { |n| keys[ints[n]] || "general" }
    end
  end

  # name -> post count, for the same names the category map admits (operator
  # ruling 2026-09-07: the hover panel shows each tag's count after it). One
  # query for the page, never one per tag, and keyed off page_tag_categories so
  # a banished name cannot reappear here after being withheld there.
  def page_tag_counts
    @page_tag_counts ||= begin
      names = page_tag_categories.keys
      counts = names.any? ? Tag.where(name: names).pluck(:name, :post_count).to_h : {}
      names.index_with { |n| counts[n].to_i }
    end
  end

  # The card's bottom-right credit: the post's first artist tag, if the
  # viewer may see one.
  def artist_for(post)
    blacklist_tags[post].to_a.find { |t| page_tag_categories[t] == "artist" }
  end

  # PROVENANCE, for the page. name -> [bucket, lamp]: bucket "creator" |
  # "both" | "auto" | "meta" | "pending", for every sidebar tag that has a
  # public provenance row on a post of this page that carries it; a name with
  # none is unsourced. One query for the page: the OR of the source flags says
  # who put the name there anywhere on the page, which is the honest answer
  # for a list that aggregates the page. Public rows only -- a private row is
  # the creator's prompt, and the pill's colour must not tell anyone else
  # what it holds.
  #
  # Fork: and only rows whose tag the post still carries (card_tags). A row
  # left behind when its tag left its post coloured every other card's pill
  # for that name (BUR review 2026-10-19). A both row is public and counts
  # as both for every viewer, as on the card (card_tag_marks).
  #
  # And THE LAMP, from the same OR: which model put the name there
  # anywhere on the page (FourierTagSource.lamp_of) -- the pill's dot, per
  # formant. A name with no row is unsourced, manual.
  def page_tag_provenance
    @page_tag_provenance ||= begin
      names = page_tag_categories.keys
      if names.empty? || posts.empty?
        {}
      else
        FourierTagSource.publicly_visible
          .where(post_id: posts.map(&:id), tag: names)
          .pluck(:post_id, :tag, :source, :status)
          .select { |post_id, tag, _, _| card_tags.fetch(post_id, Set.new).include?(tag) }
          .group_by { |_, tag, _, _| tag }
          .to_h do |tag, rows|
            source = rows.map { |_, _, bits, _| bits }.reduce(0, :|)
            pending = rows.all? { |_, _, _, status| status == FourierTagSource::PENDING }
            [tag, [provenance_bucket(source, pending), FourierTagSource.lamp_of(source)]]
          end
      end
    end
  end

  delegate :category_key, to: :PostCards

  private

  def routes
    Rails.application.routes.url_helpers
  end

  def provenance_bucket(source, pending)
    return "pending" if pending
    return "meta" if source & FourierTagSource::META > 0
    return "both" if source & FourierTagSource::CREATOR > 0 && source & FourierTagSource::AUTO > 0
    return "creator" if source & FourierTagSource::CREATOR > 0

    "auto"
  end
end
