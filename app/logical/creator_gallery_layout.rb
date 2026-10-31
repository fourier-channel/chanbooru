# frozen_string_literal: true

# A CREATOR'S GALLERY PAGE, AS THE CREATOR LAID IT OUT (Creator Gallery
# rebuild, 2026-10-23). A banner far behind, the creator's HERO BAND -- the
# posts their tags define -- and under it MINIBANDS of one tag each, in one
# of LAYOUTS. The look lives in creator_galleries.settings (defaults applied
# on read, never written until Save); each band's posts are
# CreatorGalleryPost rows (band, position).
#
# ONLY ELIGIBLE POSTS ARE CHOICES (operator ruling, 2026-10-23: a private
# post is not a valid option when it would cause visibility issues): posts
# this gallery controls (CreatorControl), image or video, not deleted, not
# jailed or banished, and public by the creator's own records -- the post's
# CreatorPostAudience row, else the gallery default (nil is public) -- and
# not kept from signed-out viewers by another gallery that also controls the
# post (narrowest wins, CreatorVisibility), or every visitor would lose it
# with nothing said to this owner. Read
# from the RECORDS, never through a viewer: a curator signed in only through
# Matrix makes a viewer-based check treat the signed-out user as the curator,
# who sees their own private posts. Everything else a viewer may not see
# (gated tags, rating, rooms, prefixes) is the draw's to filter, per viewer,
# through the showcase gate (LandingShowcase.showable?).
#
# The draw is what creator_galleries#show renders and, for a signed-out
# viewer, exactly what it grants (MembersOnly.anonymous_landing): drawn
# posts, fresh, and nothing past the cut or left undrawn.
class CreatorGalleryLayout
  HERO_MIN = 5
  HERO_MAX = 24
  MINI_MAX = 6
  CHAR_MAX = 5
  # A layout is its rows of minibands: "2-3" is two over three.
  LAYOUTS = { "2-3" => [2, 3], "3-2" => [3, 2], "1-2" => [1, 2], "2-2" => [2, 2], "1-3" => [1, 3], "4" => [4] }.freeze
  HERO_EFFECTS = %w[glide depth float].freeze
  MINI_EFFECTS = %w[slide fade drift flip depth].freeze
  HERO_DIRS = %w[left right].freeze
  MINI_DIRS = %w[left right up down].freeze
  CELLS = [3, 5, 7, 9].freeze
  HOLD = 2..12
  HEADLINE_MAX = 120
  SUBLINE_MAX = 200
  BANNER_Y = 0..100
  DEPTH = { "blur" => 0..48, "dim" => 0..85, "parallax" => 0..100 }.freeze
  # Post#is_image? and Post#is_video?, as SQL can ask them.
  MEDIA_EXTS = %w[jpg gif png webp avif webm mp4].freeze

  DEFAULTS = {
    "headline" => "",
    "subline" => "",
    "banner" => { "post_id" => nil, "y" => 50 }.freeze,
    "depth" => { "blur" => 18, "dim" => 45, "parallax" => 40 }.freeze,
    "hero" => { "tags" => [].freeze, "effect" => "glide", "dir" => "left", "hold" => 5, "cells" => 5 }.freeze,
    "layout" => "2-3",
    # The Creator Tuner's switch and where it sits (CREATOR_TUNER.md sec 4.1):
    # off until the creator turns it on, like show_contact.
    "tuner" => { "enabled" => false, "placement" => "A" }.freeze,
  }.freeze
  MINI_DEFAULT = { "tag" => "", "effect" => "slide", "dir" => "left", "hold" => 4 }.freeze

  LEGACY_NOTICE = "This gallery has no hero tags yet. Open Edit Gallery, add tags to the hero band and Save."
  NO_ORIGIN = "fourier_media_origin is not configured; set it in danbooru_local_config.rb"
  NO_PROFILE_TOKEN = "No Matrix account is configured to read profiles, and the homeserver reads them only for a signed-in one. " \
                     "Set DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN in .env.local to an access token of an account on the homeserver."

  TAG_ARRAY = "string_to_array(posts.tag_string, ' ')"
  # One row per (post, tag) of a post relation, for counting tags in SQL.
  TAG_ROWS = "CROSS JOIN LATERAL unnest(string_to_array(posts.tag_string, ' ')) AS band_tag(name)"

  AVATAR_TIMEOUT = 2

  # THE BAND RULE, the one place it is written: every non-character tag on
  # the post, and any one of the character tags (each character must be on
  # at least one chosen post -- a save check, not a post's). No tags fits
  # nothing. A miniband's rule is its one tag. #candidates asks the same
  # split in SQL.
  Rule = Data.define(:tags, :general, :characters) do
    def fits?(post)
      tags.any? && general.all? { |tag| post.tag_array.include?(tag) } && (characters.empty? || characters.any? { |tag| post.tag_array.include?(tag) })
    end
  end

  attr_reader :gallery

  def initialize(gallery)
    @gallery = gallery
  end

  # The look, defaults merged in, string keys; `minis` has one entry per slot
  # of the layout.
  def config
    @config ||= begin
      settings = gallery.settings.to_h
      layout = settings["layout"] || DEFAULTS["layout"]
      minis = Array.new(LAYOUTS.fetch(layout).sum) { |i| MINI_DEFAULT.merge(settings["minis"].to_a[i].to_h) }
      DEFAULTS.to_h { |key, value| [key, value.is_a?(Hash) ? value.merge(settings[key].to_h) : settings.fetch(key, value)] }
              .merge("layout" => layout, "minis" => minis)
    end
  end

  def rule(tags)
    tags = tags.map(&:to_s)
    characters = tags.select { |tag| categories(tags)[tag] == "character" }
    Rule.new(tags: tags, general: tags - characters, characters: characters)
  end

  # What `viewer` is shown: each band's chosen posts in order, kept when
  # eligible, fitting the band's rule (a legacy hero with no tags has none
  # yet) and showable to the viewer; and each band's tags but those hidden
  # from the viewer (#visible_names) -- a pill, a character tab and a
  # miniband's label are names like any other.
  #
  # THE GALLERY IS A LIST, bounded like every other (operator, 2026-10-18):
  # below full browsing, the first User#listing_per_page_limit distinct posts
  # across the hero then the minibands are drawn, and the rest only counted
  # (locked_count) -- drawn as empty cards carrying nothing of the post.
  #
  # owner_notices say what the owner should fix (a chosen post no longer
  # eligible or fitting, no hero tags yet); the page shows them to the owner
  # alone.
  #
  # `manager` is whoever may edit the page -- its Matrix identity, the linked
  # account or an admin; the controller knows the request, the layout does
  # not. To them the Tuner draws every harmonic, a card that does not count
  # (sec 4.6) with why, and draws it while the Tuner is off; to everyone else
  # the counting ones, and none while it is off.
  def draw(viewer, manager: gallery.managed_by?(viewer))
    banner = Post.includes(:media_asset, :uploader).find_by(id: config["banner"]["post_id"])
    stored = (config["tuner"]["enabled"] || manager) ? gallery.creator_gallery_harmonics.to_a : []
    removed = CreatorHarmonicRemoval.covering(stored.map(&:url))
    harmonics = manager ? stored : stored.select { |harmonic| harmonic.counts?(removed) }
    backgrounds = Post.includes(:media_asset, :uploader).where(id: harmonics.filter_map(&:background_post_id)).index_by(&:id)
    judged, refused = judge(viewer, [*banner&.id, *backgrounds.keys])
    kept = judged.map { |pairs| pairs.filter_map { |post, problem| post if problem.nil? && LandingShowcase.showable?(post, viewer) } }
    distinct = kept.flatten.uniq(&:id)
    # A harmonic's picture is one of the posts the page shows, so it joins
    # the cut after the bands (sec 6.3): past it, the card draws on Ground.
    pictures = harmonics.filter_map { |harmonic| backgrounds[harmonic.background_post_id] }
                        .select { |post| !refused.key?(post.id) && LandingShowcase.showable?(post, viewer) }
    listed = [*distinct, *pictures].uniq(&:id)
    allowed = viewer.can_browse_freely? ? listed : listed.first(viewer.listing_per_page_limit)
    allowed_ids = allowed.to_set(&:id)
    drawn = kept.map { |posts| posts.select { |post| allowed_ids.include?(post.id) } }
    banner = nil unless banner && !refused.key?(banner.id) && LandingShowcase.showable?(banner, viewer)

    showcase = LandingShowcase.new(viewer: viewer, posts: [*allowed, *banner])
    shown = visible_names([*config["hero"]["tags"], *config["minis"].pluck("tag")].compact_blank.uniq, viewer)
    {
      banner: banner && showcase.slide_for(banner),
      hero: { tags: pills(config["hero"]["tags"] & shown), slides: drawn.first.map { |post| showcase.slide_for(post) }},
      minis: config["minis"].zip(drawn.drop(1)).map do |mini, posts|
        { tag: pills([mini["tag"]] & shown).first, slides: posts.map { |post| showcase.slide_for(post) }}
      end,
      locked_count: distinct.count { |post| allowed_ids.exclude?(post.id) },
      owner_notices: [*(LEGACY_NOTICE if config["hero"]["tags"].empty?), *judged.flatten(1).filter_map(&:last), *refused[banner_id]].uniq,
      tuner: config["tuner"],
      harmonics: harmonics.each_with_index.map do |harmonic, i|
        post = backgrounds[harmonic.background_post_id]
        drawn_post = post if post && allowed_ids.include?(post.id)
        stale = harmonic.background_post_id && (post.nil? || refused.key?(post.id))
        notice = harmonic.owner_notice(removed, i + 1) || (CreatorGalleryHarmonic.sentence(:background_stale, n: i + 1) if stale)
        card(harmonic, i + 1, removed, drawn_post, showcase).merge(notice: (notice if manager), stale: manager && stale.present?)
      end,
    }
  end

  # The hero band's posts as the page draws them for `viewer`, before the
  # tier's cut: what the landing page's Promoted Creators row may show
  # (LandingShowcase#promoted_creator_posts) is what the gallery grants.
  # Judged as #draw judges the hero, and only the hero: the landing page asks
  # this of every promoted gallery.
  def hero_posts(viewer)
    posts = gallery.creator_gallery_posts.where(band: "hero").includes(post: [:media_asset, :uploader]).filter_map(&:post)
    refused = refusals(posts.map(&:id), viewer)
    hero_rule = rule(config["hero"]["tags"])
    posts.select { |post| !refused.key?(post.id) && misfit(post, "hero", hero_rule).nil? && LandingShowcase.showable?(post, viewer) }
  end

  # The posts a band with these tags may choose from, newest first: every
  # eligible post when `tags` is empty (the banner picker). The curator
  # chooses for everyone but is shown only what they may see: `slides` are
  # the showable ones among the newest `limit`, and `total` counts the
  # eligible posts not hidden from them. A tag hidden from them asks for
  # nothing, so neither answer tells them what it is on.
  def candidates(tags, viewer, limit: 300)
    return { total: 0, cap: limit, slides: [] } if (tags - visible_names(tags, viewer)).any?

    band_rule = rule(tags)
    parts = eligible_parts.map do |part|
      part = part.without_hidden_posts(viewer)
      part = part.where_array_includes_all(TAG_ARRAY, band_rule.general) if band_rule.general.any?
      band_rule.characters.any? ? part.where_array_includes_any(TAG_ARRAY, band_rule.characters) : part
    end
    posts = parts.flat_map { |part| part.includes(:media_asset, :uploader).order(id: :desc).limit(limit).to_a }.sort_by { |post| -post.id }.first(limit)
                 .select { |post| LandingShowcase.showable?(post, viewer) }
    showcase = LandingShowcase.new(viewer: viewer, posts: posts)

    { total: parts.sum(&:count), cap: limit, slides: posts.map { |post| showcase.slide_for(post) }}
  end

  # The tags on the eligible posts, most used first, but those hidden from
  # the curator (#visible_names); each count is over the eligible posts not
  # hidden from them. A
  # creator's private tag is never in tag_string, so it is never offered:
  # band tags are shown to everyone.
  def palette(viewer, limit: 200)
    counts = eligible_parts.map { |part| part.without_hidden_posts(viewer).joins(TAG_ROWS).group("band_tag.name").count }
                           .reduce({}) { |sum, part| sum.merge(part) { |_, a, b| a + b } }
    counts = counts.slice(*visible_names(counts.keys, viewer))
    top = counts.sort_by { |name, count| [-count, name] }.first(limit)
    kinds = categories(top.map(&:first))
    top.map { |name, count| { name: name, category: kinds[name] || "general", count: count } }
  end

  # Save the look and the Page fields (title, bio, matrix_contact and the two
  # switches, page_private and show_contact) at once,
  # under the gallery's lock, or nothing at all.
  #
  # @param page [Hash] the gallery's own fields, checked by its validations
  # @param look [Hash] the settings shape plus each band's `posts` (ids in order)
  # @param viewer [User] the curator, to whom a tag hidden from them is no tag
  # @return [Array<String>] [] when saved, else every problem, each naming its remedy
  def save(page:, look:, viewer:)
    look = look.to_h.deep_stringify_keys
    page = page.to_h.stringify_keys.slice("title", "bio", "matrix_contact", "page_private", "show_contact")
    banner = look["banner"].to_h
    depth = look["depth"].to_h
    hero = look["hero"].to_h
    layout = look["layout"]
    # The editor keeps minibands past the layout's count, so a layout can be
    # switched back without losing them; only the layout's own are saved.
    minis = look["minis"].to_a.map(&:to_h).first(LAYOUTS[layout]&.sum || 0)
    hero_tags = Array(hero["tags"]).map { |tag| tag.to_s.strip }.compact_blank.uniq
    mini_tags = minis.map { |mini| mini["tag"].to_s.strip }
    banner_id = whole(banner["post_id"]) if banner["post_id"].present?
    bands = [["hero", post_ids(hero["posts"])], *minis.each_with_index.map { |mini, i| ["mini#{i + 1}", post_ids(mini["posts"])] }]
    refused = refusals([*bands.flat_map(&:last), *banner_id].compact.uniq, viewer)
    posts = Post.where(id: bands.flat_map(&:last).compact.uniq - refused.keys).index_by(&:id)
    tag_refusals = refused_tags([*hero_tags, *mini_tags].compact_blank.uniq, viewer)
    hero_rule = rule(hero_tags - tag_refusals.keys)
    hero_ids = bands.first.last
    tuner = look["tuner"]&.to_h
    # Absent leaves the harmonics as they are; an empty list removes the owner's.
    harmonics = look["harmonics"]&.map(&:to_h)

    problems = [
      (CreatorGalleryHarmonic.sentence(:placement, value: "\"#{tuner["placement"]}\"", allowed: CreatorGalleryHarmonic::PLACEMENTS.join(", ")) if tuner && CreatorGalleryHarmonic::PLACEMENTS.exclude?(tuner["placement"])),
      ("The headline is #{look["headline"].to_s.length} characters; #{HEADLINE_MAX} is the most. Shorten it." if look["headline"].to_s.length > HEADLINE_MAX),
      ("The subline is #{look["subline"].to_s.length} characters; #{SUBLINE_MAX} is the most. Shorten it." if look["subline"].to_s.length > SUBLINE_MAX),
      ("The banner's position must be a whole number from #{BANNER_Y.min} to #{BANNER_Y.max}." unless BANNER_Y.cover?(whole(banner["y"]))),
      ("The banner must be a post id. Pick it from the list." if banner["post_id"].present? && banner_id.nil?),
      refused[banner_id],
      *DEPTH.map { |key, range| "The depth's #{key} must be a whole number from #{range.min} to #{range.max}." unless range.cover?(whole(depth[key])) },
      choice("The hero band's effect", hero["effect"], HERO_EFFECTS),
      choice("The hero band's direction", hero["dir"], HERO_DIRS),
      ("The hero band's hold must be a whole number of seconds from #{HOLD.min} to #{HOLD.max}." unless HOLD.cover?(whole(hero["hold"]))),
      choice("The hero band's cells", whole(hero["cells"]), CELLS),
      choice("The layout", layout, LAYOUTS.keys),
      ("The layout #{layout} has #{LAYOUTS[layout].sum} minibands; #{minis.size} were sent." if LAYOUTS.key?(layout) && minis.size < LAYOUTS[layout].sum),
      *tag_refusals.values,
      ("The hero band has no tags. Add one with + Tag on the band." if hero_tags.empty?),
      ("The hero band holds #{hero_ids.size} of the #{HERO_MIN} posts it needs. Open Posts on the band and pick more." if hero_ids.size < HERO_MIN),
      ("The hero band holds #{hero_ids.size} posts; #{HERO_MAX} is the most. Take some off." if hero_ids.size > HERO_MAX),
      ("The hero band has more than #{CHAR_MAX} character tags. Take one off." if hero_rule.characters.size > CHAR_MAX),
      *hero_rule.characters.filter_map do |tag|
        "#{tag} is on none of the band's posts. Pick a post that has it, or take the tag off." if hero_ids.none? { |id| posts[id]&.tag_array&.include?(tag) }
      end,
      *band_post_problems("hero", hero_ids, hero_rule, refused, posts),
      *minis.each_with_index.flat_map do |mini, i|
        label = "Miniband #{i + 1}"
        ids = bands[i + 1].last
        [
          ("#{label} has no tag. Pick one on the miniband." if mini_tags[i].blank?),
          choice("#{label}'s effect", mini["effect"], MINI_EFFECTS),
          choice("#{label}'s direction", mini["dir"], MINI_DIRS),
          ("#{label}'s hold must be a whole number of seconds from #{HOLD.min} to #{HOLD.max}." unless HOLD.cover?(whole(mini["hold"]))),
          ("#{label} has no posts. Open Posts on it and pick at least one." if mini_tags[i].present? && ids.empty?),
          ("#{label} holds #{ids.size} posts; #{MINI_MAX} is the most." if ids.size > MINI_MAX),
          *band_post_problems("mini#{i + 1}", ids, rule([mini_tags[i]].compact_blank - tag_refusals.keys), refused, posts),
        ]
      end,
    ].compact.uniq

    gallery.with_lock do
      # with_lock reloads the gallery, so the Page fields are assigned inside it.
      gallery.assign_attributes(page)
      problems += gallery.errors.full_messages unless gallery.valid?
      # Checked under the lock, against the rows as they stand: an admin's
      # hide may have landed since the editor loaded.
      planned, refused_harmonics = harmonics ? plan_harmonics(harmonics, viewer) : [nil, []]
      problems += refused_harmonics
      if problems.any?
        gallery.restore_attributes
        next
      end

      gallery.update!(settings: gallery.settings.merge(
        "headline" => look["headline"].to_s,
        "subline" => look["subline"].to_s,
        "banner" => { "post_id" => banner_id, "y" => whole(banner["y"]) },
        "depth" => DEPTH.keys.index_with { |key| whole(depth[key]) },
        "hero" => { "tags" => hero_tags, "effect" => hero["effect"], "dir" => hero["dir"], "hold" => whole(hero["hold"]), "cells" => whole(hero["cells"]) },
        "layout" => layout,
        "minis" => minis.zip(mini_tags).map { |mini, tag| { "tag" => tag, "effect" => mini["effect"], "dir" => mini["dir"], "hold" => whole(mini["hold"]) } },
        **({ "tuner" => { "enabled" => tuner["enabled"].to_s.truthy?, "placement" => tuner["placement"] }} if tuner),
      ))
      if planned
        # Upserted by id with what plan_harmonics allows, never rewritten
        # whole: a staff hide lives in the row's own columns (sec 4.2).
        planned.each_with_index { |(harmonic, attributes), position| harmonic.update!(**attributes, position: position) }
        gallery.creator_gallery_harmonics.where.not(id: planned.map { |harmonic, _| harmonic.id }).where(staff_hidden_at: nil).delete_all
        gallery.creator_gallery_harmonics.reset
      end
      CreatorGalleryPost.where(creator_gallery_id: gallery.id).delete_all
      rows = bands.flat_map { |band, ids| ids.each_with_index.map { |id, position| { creator_gallery_id: gallery.id, band: band, post_id: id, position: position } } }
      CreatorGalleryPost.insert_all!(rows) if rows.any? # rubocop:disable Rails/SkipsModelValidations -- every row was checked above, under the lock
      gallery.creator_gallery_posts.reset
    end
    @config = nil
    problems
  end

  # One more post at the end of a band (creator_galleries#add_post, the API's
  # door), refused as a save by `viewer` would refuse it. A post already on
  # the band stays where it is.
  #
  # @return [String, nil] the problem, nil when the post is on the band
  def add(post, band, viewer)
    bands = ["hero", *config["minis"].each_index.map { |i| "mini#{i + 1}" }]
    return "There is no band #{band}. Use #{words(bands, "or")}." unless bands.include?(band)

    tags = (band == "hero") ? config["hero"]["tags"] : [config["minis"][band.delete_prefix("mini").to_i - 1]["tag"]].compact_blank
    gallery.with_lock do
      rows = gallery.creator_gallery_posts.where(band: band)
      next nil if rows.exists?(post_id: post.id)

      max = (band == "hero") ? HERO_MAX : MINI_MAX
      place = (band == "hero") ? "The hero band" : "Miniband #{band.delete_prefix("mini")}"
      problem = refusals([post.id], viewer)[post.id] || misfit(post, band, rule(tags)) ||
        ("#{place} holds #{max} posts; #{max} is the most. Take one off first." if rows.count >= max)
      rows.create!(post: post, position: (rows.maximum(:position) || -1) + 1) if problem.nil?
      problem
    end
  end

  # The creator's Matrix name and avatar, read from their homeserver profile
  # through fourier_media_origin as the account fourier_matrix_profile_token
  # names -- the homeserver answers profiles only to a signed-in account
  # (require_auth_for_profile_requests, 2026-10-02, against enumeration) --
  # and cached (an hour; a failure ten minutes,
  # so a fix shows soon). `url` is the avatar's thumbnail for a viewer who
  # can load Matrix media -- fourier-auth answers 401 to a signed-out one,
  # who gets nil and a monogram, by design. `problem` is for the owner.
  #
  # @return [Hash] { name:, mxc:, url:, problem: }
  def avatar(viewer)
    origin = Danbooru.config.fourier_media_origin.presence&.chomp("/")
    return { name: nil, mxc: nil, url: nil, problem: NO_ORIGIN } if origin.nil?
    token = Danbooru.config.fourier_matrix_profile_token.presence
    return { name: nil, mxc: nil, url: nil, problem: NO_PROFILE_TOKEN } if token.nil?

    key = "creator-gallery-avatar:#{gallery.matrix_id.downcase}"
    profile = Rails.cache.read(key)
    if profile.nil?
      url = "#{origin}/_matrix/client/v3/profile/#{ERB::Util.url_encode(gallery.matrix_id)}"
      response = Danbooru::Http.internal.timeout(AVATAR_TIMEOUT).headers(Accept: "application/json", Authorization: "Bearer #{token}").get(url)
      data = begin
        JSON.parse(response.body.to_s) if response.code == 200
      rescue JSON::ParserError
        nil
      end

      if data.is_a?(Hash)
        name = data["displayname"]
        mxc = data["avatar_url"]
        profile = { name: name.is_a?(String) ? name.presence : nil, mxc: (mxc.is_a?(String) && mxc.match?(MatrixMedia::MXC)) ? mxc : nil, problem: nil }
        Rails.cache.write(key, profile, expires_in: 1.hour)
      else
        why = (response.code == 200) ? "answered 200 with something that is not a profile" : "answered HTTP #{response.code}"
        if response.code.in?([401, 403])
          remedy = "The homeserver refused the profile reader's token: set DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN in .env.local to a live access token."
        else
          remedy = "Check that fourier_media_origin reaches the homeserver's client API."
        end
        profile = { name: nil, mxc: nil, problem: "The Matrix profile of #{gallery.matrix_id} could not be read: #{url} #{why}. #{remedy}" }
        Rails.logger.warn("creator gallery: #{profile[:problem]}")
        Rails.cache.write(key, profile, expires_in: 10.minutes)
      end
    end

    server, media_id = profile[:mxc]&.delete_prefix("mxc://")&.split("/", 2)
    thumb = "#{origin}/_matrix/client/v1/media/thumbnail/#{server}/#{media_id}?width=96&height=96&method=crop" if server
    profile.merge(url: MembersOnly.signed_out?(viewer, CurrentUser.request) ? nil : thumb)
  end

  # Tag names as the page's pills: { name:, category: }, a name with no Tag
  # row as general.
  def pills(names)
    kinds = categories(names)
    names.map { |name| { name: name, category: kinds[name] || "general" } }
  end

  private

  def banner_id
    config["banner"]["post_id"]
  end

  # A harmonic as the page draws it (sec 2). `post` is its background when
  # this viewer is drawn it; else nil, and nothing in the card names the post
  # (sec 2.6: omitted on the server, not hidden in CSS) -- it draws on Ground,
  # or its gradient, link intact.
  def card(harmonic, number, removed, post, showcase)
    site = harmonic.site_entry
    host = harmonic.host
    {
      id: harmonic.id,
      number: number,
      shown: harmonic.shown,
      counts: harmonic.counts?(removed),
      url: harmonic.url,
      host: host,
      domain: CreatorGalleryHarmonic.domain(host),
      site: harmonic.site,
      name: site&.name || harmonic.site,
      logo: site&.logo,
      support: site&.support || false,
      adult: site&.adult || false,
      title: harmonic.title,
      subtitle: harmonic.subtitle,
      cta: harmonic.cta,
      cta_label: CreatorGalleryHarmonic::CTAS[harmonic.cta],
      places: harmonic.places,
      gradient: harmonic.background_gradient,
      picture: post && showcase.slide_for(post).slice(:id, :tags, :rating, :flags, :score, :uploader_id, :w, :h).merge(
        src: post.media_asset.has_variant?(:"720x720") ? post.media_asset.variant(:"720x720").file_url : post.file_url,
        focus_x: harmonic.focus_x, focus_y: harmonic.focus_y, zoom: harmonic.zoom, shade: harmonic.shade,
      ),
    }
  end

  # The owner's list of harmonics as the rows to write, in order, or every
  # problem with it (sec 3.4, 4.2): each entry's link, words, places and
  # background, then the list's own rules -- one page per link, one support
  # link, the cap on counting harmonics, the rows kept. A staff-hidden row is
  # never the owner's to change (sec 4.3): in the list it only moves; left
  # out, it stays, after the list. A row whose site left the list keeps its
  # link unchecked while the link is unchanged, so the site's return restores
  # it (sec 4.6).
  #
  # @param entries [Array<Hash>] the editor's list, string keys
  # @return [Array(Array<Array(CreatorGalleryHarmonic, Hash)>, Array<String>)]
  #   [[row, attributes], ...] and [], or nil and the problems
  def plan_harmonics(entries, viewer)
    stored = gallery.creator_gallery_harmonics.reload.index_by(&:id)
    numbered = entries.each_with_index.map do |entry, i|
      row = entry["id"].present? ? stored[whole(entry["id"])] : CreatorGalleryHarmonic.new(creator_gallery: gallery)
      [entry, row, i + 1]
    end
    owned = numbered.select { |_, row, _| row && !row.staff_hidden? }
    links = owned.to_h do |entry, row, n|
      kept = row.persisted? && row.site_entry.nil? && entry["url"].to_s == row.url
      [n, kept ? { url: row.url, host: row.host, site: row.site } : CreatorGalleryHarmonic.link(entry["url"])]
    end
    removed = CreatorHarmonicRemoval.covering(links.values.filter_map { |link| link[:url] })
    refused = refusals(owned.filter_map { |entry, _, _| whole(entry["background_post_id"]) }.uniq, viewer)
    limits = CreatorGalleryHarmonic::LIMITS
    say = ->(key, **vars) { CreatorGalleryHarmonic.sentence(key, **vars) }

    checked = owned.map do |entry, _, n|
      link = links[n]
      title = entry["title"].to_s.strip
      subtitle = entry["subtitle"].to_s.strip
      cta = entry["cta"].presence
      places = entry["places"].to_h.stringify_keys.slice(*CreatorGalleryHarmonic::ELEMENTS)
      post_id = whole(entry["background_post_id"]) if entry["background_post_id"].present?
      gradient = whole(entry["background_gradient"]) if entry["background_gradient"].present?
      picture = entry["background_post_id"].present?
      settings = { "focus_x" => ["focus x", limits["focus"]], "focus_y" => ["focus y", limits["focus"]], "zoom" => ["zoom", limits["zoom"]], "shade" => ["shade", limits["shade"]] }
      values = settings.keys.index_with { |key| whole(entry[key]) }
      # Drawn at the smallest size (160 px, sec 2.5) only the mark, the title
      # and the host draw. A row holding a centre and a side place splits into
      # thirds of the safe area (86% of the width, sec 2.3); the host's mono
      # face at 11 px takes 6.6 px a character, and must keep its domain.
      domain = CreatorGalleryHarmonic.domain(link[:host]) if link[:host]
      host_row = places.slice("mark", "title", "host").values.compact_blank.select { |place| place[0] == places["host"].to_s[0] }
      split = host_row.any? { |place| place[1] == "c" } && host_row.any? { |place| place[1] != "c" }
      problems = [
        (say.call(link[:problem], n: n, **link[:vars]) if link[:problem]),
        (say.call(:link_removed, url: link[:url].delete_prefix("https://")) if link[:url] && removed.include?(link[:url])),
        (say.call(:title_blank, n: n, max: limits["title"]) if title.empty?),
        (say.call(:title_long, n: n, length: title.length, max: limits["title"]) if title.length > limits["title"]),
        (say.call(:subtitle_long, n: n, length: subtitle.length, max: limits["subtitle"]) if subtitle.length > limits["subtitle"]),
        (say.call(:cta, n: n, value: "\"#{cta}\"", allowed: CreatorGalleryHarmonic::CTAS.keys.join(", ")) if cta && !CreatorGalleryHarmonic::CTAS.key?(cta)),
        *CreatorGalleryHarmonic::ELEMENTS.filter_map do |element|
          next if element == "mark" && places[element].blank?
          say.call(:place, n: n, element: element, value: "\"#{places[element]}\"", allowed: CreatorGalleryHarmonic::PLACES.join(", ")) if CreatorGalleryHarmonic::PLACES.exclude?(places[element])
        end,
        (say.call(:background_both, n: n) if picture && entry["background_gradient"].present?),
        (say.call(:gradient, n: n, value: "\"#{entry["background_gradient"]}\"", allowed: CreatorGalleryHarmonic::GRADIENTS.map { |key, name| "#{key} (#{name})" }.join(", ")) if !picture && entry["background_gradient"].present? && !CreatorGalleryHarmonic::GRADIENTS.key?(gradient)),
        (say.call(:background_stale, n: n) if picture && (post_id.nil? || refused.key?(post_id))),
        *(picture ? settings : {}).filter_map do |key, (label, (min, max))|
          say.call(:range, n: n, setting: label, value: entry[key].to_s.presence || "empty", min: min, max: max) unless values[key]&.between?(min, max)
        end,
        (say.call(:shade_floor, n: n, value: values["shade"], floor: limits["shade_floor"]) if picture && values["shade"]&.between?(*limits["shade"]) && values["shade"] < limits["shade_floor"]),
        (say.call(:host_fit, n: n, domain: domain) if domain && split && domain.length * 6.6 > 160 * 0.86 / 3),
      ].compact
      attributes = {
        shown: entry.key?("shown") ? entry["shown"].to_s.truthy? : true,
        site: link[:site], url: link[:url], title: title, subtitle: subtitle, cta: cta, places: places.compact_blank,
        background_post_id: post_id, background_gradient: (gradient unless picture),
        **settings.keys.to_h { |key| [key.to_sym, (values[key] if picture)] },
      }
      [n, attributes, problems]
    end
    attributes = checked.to_h { |n, attrs, _| [n, attrs] }

    pages = checked.filter_map { |n, attrs, _| [n, attrs[:url]] if attrs[:url] }.group_by(&:last).values.find { |pair| pair.size > 1 }
    # The later of the first two support links is the one refused.
    first, second = checked.select { |_, attrs, _| CreatorGalleryHarmonic::SITES[attrs[:site]]&.support }
    counting = checked.count { |_, attrs, _| attrs[:shown] && CreatorGalleryHarmonic::SITES.key?(attrs[:site]) && removed.exclude?(attrs[:url]) }
    left_out = stored.values.select(&:staff_hidden?) - numbered.map { |_, row, _| row }
    twice = numbered.select { |_, row, _| row&.persisted? }.group_by { |_, row, _| row.id }.values.find { |listed| listed.size > 1 }
    cap = gallery.harmonic_cap
    over = ->(count, most) { (count - most == 1) ? "one" : count - most }
    problems = [
      *numbered.filter_map { |_, row, n| say.call(:unknown, n: n) if row.nil? },
      (say.call(:same_row, a: twice[0][2], b: twice[1][2]) if twice),
      *checked.flat_map(&:last),
      (say.call(:duplicate, a: pages[0][0], b: pages[1][0]) if pages),
      (say.call(:support_twice, a: second[0], b: first[0], site_a: CreatorGalleryHarmonic::SITES[second[1][:site]].name, site_b: CreatorGalleryHarmonic::SITES[first[1][:site]].name) if second),
      (say.call(:cap, count: counting, cap: cap, over: over.call(counting, cap)) if counting > cap),
      (say.call(:rows, count: entries.size + left_out.size, max: limits["rows"], over: over.call(entries.size + left_out.size, limits["rows"])) if entries.size + left_out.size > limits["rows"]),
    ].compact.uniq
    return [nil, problems] if problems.any?

    [[*numbered.map { |_, row, n| [row, attributes.fetch(n, {})] }, *left_out.map { |row| [row, {}] }], []]
  end

  # The eligible posts, as CreatorControl's parts narrowed in SQL -- each
  # part queried on its own, never ORed (see gallery_post_parts). The posts
  # hidden from a signed-out viewer are read from the records alone
  # (CreatorVisibility asks User.anonymous nothing of the request).
  def eligible_parts
    audiences = CreatorPostAudience.where(creator_gallery_id: gallery.id)
    hidden = CreatorVisibility.hidden_ids_literal(User.anonymous)
    CreatorControl.gallery_post_parts([[gallery.id, gallery.matrix_id]]).map do |part|
      part = part.where(is_deleted: false, file_ext: MEDIA_EXTS).where_array_includes_none(TAG_ARRAY, TagBanishment.post_tags)
      part = part.where("posts.id NOT IN (SELECT unnest(?::integer[]))", hidden) if hidden
      if gallery.default_audience.in?(%w[groups private])
        part.where(id: audiences.where(audience: "public").select(:post_id))
      else
        part.where.not(id: audiences.where(audience: %w[groups private]).select(:post_id))
      end
    end
  end

  # Each band's chosen posts in order, paired with why each is not drawn
  # (nil when it is): refused (#refusals), or not fitting the band's rule.
  # The refusals cover `more` too.
  #
  # @return [Array(Array<Array(Post, String)>, Hash{Integer => String})]
  def judge(viewer, more = [])
    rows = gallery.creator_gallery_posts.includes(post: [:media_asset, :uploader]).group_by(&:band).transform_values { |list| list.filter_map(&:post) }
    refused = refusals([*rows.values.flatten.map(&:id), *more].uniq, viewer)
    bands = [["hero", rule(config["hero"]["tags"])], *config["minis"].each_with_index.map { |mini, i| ["mini#{i + 1}", rule([mini["tag"]].compact_blank)] }]
    [bands.map { |band, band_rule| rows[band].to_a.map { |post| [post, refused[post.id] || misfit(post, band, band_rule)] } }, refused]
  end

  # Why each of these posts is not a valid choice, as a problem naming its
  # remedy; eligible posts are absent. A post hidden from `viewer` is
  # answered as no post at all, eligible or not, or the answer would tell
  # them it exists -- and, eligible, that it is the creator's, live and public.
  #
  # @return [Hash{Integer => String}]
  def refusals(ids, viewer)
    return {} if ids.empty?

    posts = Post.where(id: ids).without_hidden_posts(viewer).index_by(&:id)
    eligible = posts.empty? ? [] : eligible_parts.flat_map { |part| part.where(id: posts.keys).pluck(:id) }
    rest = ids - eligible
    return {} if rest.empty?

    controllers = CreatorControl.controller_gallery_ids(posts.values)
    # A row set back to the default is kept, as "inherit" (CreatorPostAudience.set!).
    audiences = CreatorPostAudience.where(creator_gallery_id: gallery.id, post_id: rest).pluck(:post_id, :audience).to_h
    rest.index_with do |id|
      post = posts[id]
      audience = audiences[id].presence_in(%w[public groups private]) || gallery.default_audience
      if post.nil?
        reason = "there is no such post"
      elsif controllers[id].exclude?(gallery.id)
        reason = "it is not one of your posts"
      elsif post.is_deleted?
        reason = "it is deleted"
      elsif MEDIA_EXTS.exclude?(post.file_ext)
        reason = "it is not an image or a video"
      elsif TagBanishment.post_tags.intersect?(post.tag_array)
        reason = "it is withheld from the site"
      elsif audience.in?(%w[groups private])
        reason = "its audience is #{(audience == "groups") ? "your groups" : audience}"
      else
        reason = "another creator who shares it keeps it from signed-out viewers"
      end
      remedy = (post && reason.start_with?("its audience")) ? "Make it public on Who sees your posts, or take it off." : "Take it off."
      "Post ##{id} cannot be chosen: #{reason}. #{remedy}"
    end
  end

  # Why a chosen, eligible post is not in its band: the band's rule does not
  # fit it. nil when it fits, or for a hero with no tags yet (a legacy
  # gallery, drawn as chosen).
  def misfit(post, band, band_rule)
    return nil if band_rule.fits?(post) || (band == "hero" && band_rule.tags.empty?)
    return "#{band.sub("mini", "Miniband ")} has no tag. Pick one on the miniband." if band_rule.tags.empty?

    missing = band_rule.general - post.tag_array
    carry = missing.any? ? words(missing, "and") : "any of #{words(band_rule.characters, "or")}"
    remedy = (band == "hero") ? "Take it off the band or change the band's tags." : "Take it off miniband #{band.delete_prefix("mini")} or change its tag."
    "Post ##{post.id} does not carry #{carry}. #{remedy}"
  end

  # A band's posts: each one twice, refused, or not fitting its rule.
  def band_post_problems(band, ids, band_rule, refused, posts)
    place = (band == "hero") ? "the hero band" : "miniband #{band.delete_prefix("mini")}"
    [
      ("#{place.upcase_first}'s posts must be post ids. Pick posts from the list." if ids.any?(nil)),
      *ids.compact.tally.select { |_, n| n > 1 }.keys.map { |id| "Post ##{id} is on #{place} twice. Take one off." },
      *ids.compact.uniq.map { |id| refused[id] || (misfit(posts[id], band, band_rule) if band_rule.tags.any?) },
    ]
  end

  # Band tags that cannot be used, as problems naming the remedy: a tag
  # private to the creator (on their posts only as a private creator tag,
  # never in a tag_string) -- said so only to a viewer who may read it on one
  # of those posts (FourierCreatorPrivacy.readable_post_ids: the creator
  # themselves, not an admin or an owner over another's post) -- then one this
  # booru does not have -- as is, to `viewer`, one hidden from them or private
  # to someone else, or the answer would tell them it exists. Band tags are
  # shown to everyone.
  #
  # @return [Hash{String => String}]
  def refused_tags(names, viewer)
    return {} if names.empty?

    kinds = categories(names)
    hidden = names - visible_names(names, viewer)
    unknown = names.select { |name| kinds[name].nil? || hidden.include?(name) }
    sources = CreatorControl.gallery_post_parts([[gallery.id, gallery.matrix_id]]).flat_map do |part|
      FourierTagSource.where(public: false, tag: unknown, post_id: part.select(:id)).distinct.pluck(:post_id, :tag)
    end
    readable = FourierCreatorPrivacy.readable_post_ids(Post.where(id: sources.map(&:first).uniq).to_a, viewer, CurrentUser.request)
    privately = sources.filter_map { |post_id, tag| tag if readable.include?(post_id) }
    unknown.index_with do |name|
      (privately.include?(name) && hidden.exclude?(name)) ? "#{name} is private to you. Pick a public tag." : "#{name} is not a tag on this booru. Pick tags from the list."
    end
  end

  # The names among `names` that `viewer` may be shown: none that
  # Tag#hidden_from? would withhold, asked the same way of a few names.
  def visible_names(names, viewer)
    names - Tag.hidden_names_for(viewer, by_creator: false) - CreatorVisibility.hidden_tag_names_among(viewer, names)
  end

  # Tag name => category name ("general", "character", ...), nil for a name
  # with no Tag row. Remembered per name, one query for the names not yet seen.
  def categories(names)
    @categories ||= {}
    missing = names - @categories.keys
    if missing.any?
      found = Tag.where(name: missing).pluck(:name, :category).to_h
      @categories.merge!(missing.index_with { |name| found[name] && TagCategory.reverse_mapping[found[name]] })
    end
    @categories.slice(*names)
  end

  def post_ids(list)
    Array(list).map { |id| whole(id) }
  end

  def whole(value)
    value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)
  end

  def choice(label, value, allowed)
    "#{label} must be one of #{words(allowed, "or")}." unless allowed.include?(value)
  end

  # "a, b and c" -- the prototype's words().
  def words(list, last)
    list.map(&:to_s).to_sentence(words_connector: ", ", two_words_connector: " #{last} ", last_word_connector: " #{last} ")
  end
end
