# frozen_string_literal: true

# The Creator Gallery page, in the Modulation theme: the creator's banner as a
# far ground, their Matrix avatar and name, the HERO BAND -- the landing
# page's own belt, riding the posts the creator chose under the band's tags --
# and the MINIBANDS beneath it in the creator's layout, one tag each
# (CreatorGalleryLayout; the operator's brief, 2026-10-23).
#
# What is drawn is `draw`, CreatorGalleryLayout#draw for this viewer: every
# post in it is one the viewer may see, and the posts past the browsing tier's
# cut are only counted (locked_count). The look -- motion, layout, depth --
# is the gallery's settings, read through the same CreatorGalleryLayout.
#
# `editing` is the same page with options on everything (the creator's edit
# page): the editor in creator_gallery_component.js works on a draft of the
# look and the band's posts and saves it in one PATCH; `panels` are the edit
# page's own sections, which keep their own forms and routes.
#
# `closed` is a private page this viewer is not let in to
# (CreatorGallery#page_open_to?): its banner and avatar alone.
class CreatorGalleryComponent < ApplicationComponent
  # A miniband slot's height and narrowest width by how many share its row:
  # the prototype's ROW_H and MIN_W, as creator_gallery_model.js has them.
  ROW_H = { 1 => 340, 2 => 300, 3 => 250, 4 => 230 }.freeze
  MIN_W = { 1 => 560, 2 => 360, 3 => 250, 4 => 220 }.freeze

  attr_reader :gallery, :viewer, :draw, :avatar, :can_edit, :editing, :palette, :panels, :closed, :scan, :wheel, :about_open, :box_states

  # @param draw [Hash] CreatorGalleryLayout#draw(viewer)
  # @param avatar [Hash] CreatorGalleryLayout#avatar(viewer): { name:, mxc:, url:, problem: }
  # @param palette [Array<Hash>] CreatorGalleryLayout#palette, in edit mode
  # @param panels [Hash{String => String}] the edit page's sections, title => HTML, in edit mode
  # @param scan [Boolean, nil] the viewer's Tuner Scan (ModulationSetting tuner_scan)
  # @param wheel [Boolean] the hero band's wheel is the viewer's to step it (ModulationSetting wheel_scroll)
  # @param about_open [Boolean] About starts open (ModulationSetting creator_about_open)
  # @param about_boxes [Hash] each About box as the viewer left it, by kind (ModulationSetting creator_about_boxes)
  def initialize(gallery:, viewer:, draw:, avatar:, can_edit:, scan:, editing: false, palette: nil, panels: nil, closed: false, wheel: false, about_open: true, about_boxes: {}) # rubocop:disable Metrics/ParameterLists
    super
    @scan = scan
    @wheel = wheel
    @about_open = about_open
    @box_states = about_boxes
    @closed = closed
    @gallery = gallery
    @viewer = viewer
    @draw = draw
    @avatar = avatar
    @can_edit = can_edit
    @editing = editing
    @palette = palette
    @panels = panels
  end

  def layout
    @layout ||= CreatorGalleryLayout.new(gallery)
  end

  def look
    layout.config
  end

  def title
    gallery.title.presence || gallery.slug
  end

  # The disc's letter when there is no avatar to show: the Matrix name's, else
  # the page's. A closed page names no one, so its letter is its address's.
  def monogram
    (closed ? gallery.slug : (avatar[:name].presence || title)).delete_prefix("@")[0].to_s.upcase
  end

  # The Tuner's placement, "A" or "B", when the page draws one: switched on,
  # with a card this viewer is drawn, on a page open to them.
  def tuner
    draw[:tuner]["placement"] if !closed && draw[:tuner]["enabled"] && draw[:harmonics].any?
  end

  def hero_slides
    draw[:hero][:slides]
  end

  # The belt's rows: every post in the band, then one row per character of the
  # band's that is on at least one of them -- the belt's own axis tabs are the
  # character filter. A band with no posts has no rows, and no belt boots.
  def hero_categories
    characters = draw[:hero][:tags].select { |tag| tag[:category] == "character" }
    rows = characters.map { |tag| { key: "c-#{tag[:name]}", label: tag[:name].tr("_", " "), slides: hero_slides.select { |slide| slide[:tags].split.include?(tag[:name]) }} }
    [{ key: "all", label: "All", slides: hero_slides }, *rows].select { |row| row[:slides].any? }
  end

  # ModulationLandingComponent#config's keys, minus the refresh: the band is a
  # fixed list the creator chose, not a draw that goes stale.
  def belt_config
    hero = look["hero"]
    {
      creditPhrases: TagSetPresenter::CREDIT_PHRASES,
      categories: hero_categories,
      advanceMs: hero["hold"] * 1_000,
      resumeMs: 10_000,
      direction: (hero["dir"] == "left") ? 1 : -1,
      cells: hero["cells"],
      effect: hero["effect"],
      holdAxis: true,
      scopedKeys: true,
      hoverPause: true,
      liveCreators: CreatorActivity.active(hero_slides.filter_map { |slide| slide.dig(:creator, :tag) }.uniq, viewer: viewer),
      liveWindow: Danbooru.config.creator_active_window.to_i,
    }
  end

  # The minibands in the layout's rows: [[{ i:, n:, mini:, look: }, ...], ...],
  # n being how many share the row.
  def mini_rows
    counts = CreatorGalleryLayout::LAYOUTS.fetch(look["layout"])
    counts.each_with_index.map do |n, r|
      from = counts.take(r).sum
      (from...(from + n)).map { |i| { i: i, n: n, mini: draw[:minis][i], look: look["minis"][i] } }
    end
  end

  # The modulation pill for a tag: the identifying categories by colour, a
  # meta tag as meta, and a general tag in the provenance treatment that
  # paints an unidentified pill.
  def pill_class(category)
    case category
    when "artist", "copyright", "character" then "mod-pill mod-pill--cat mod-pill--cat-#{category}"
    when "meta" then "mod-pill mod-pill--meta"
    else "mod-pill mod-pill--unsourced"
    end
  end

  # What the blacklist matches a drawn post on: the pool item's attributes.
  def marks(slide)
    slide.slice(:id, :tags, :rating, :flags, :score, :uploader_id)
  end

  # A miniband's picture: the sample for an image, the preview for anything
  # else (a video's sample is the video).
  def picture(slide)
    (slide[:kind] == "image") ? slide[:src] : slide[:thumb]
  end

  # The banner's picture, on both layers: full size, since the banner spans
  # the window (LandingShowcase#full_url).
  def banner_picture(slide)
    slide[:full] || picture(slide)
  end

  # The look as CSS variables: the ground's blur and dim, the parallax's
  # strength, the banner's focus, and the banner post's applied view, which
  # both layers compose after the parallax (CreatorGalleryPostView).
  def depth_style
    depth = look["depth"]
    view = CreatorGalleryPostView.style(draw[:banner]&.dig(:view))
    ["--cg-blur: #{depth["blur"]}px; --cg-dim: #{depth["dim"] / 100.0}; --cg-par: #{depth["parallax"] / 100.0}; --cg-y: #{look["banner"]["y"]}%", view.presence].compact.join("; ")
  end

  # What the editor starts from: the saved look with each band's tags and
  # posts AS STORED -- never the curator's draw, which leaves out what is
  # hidden from them, so a Save would drop it (the editor shows a post it has
  # no slide for as its number, to keep or take off) -- the slides it has
  # already seen, the tags it may use, and where it asks and saves.
  def editor_data
    stored = gallery.creator_gallery_posts.group_by(&:band).transform_values { |rows| rows.map(&:post_id) }
    {
      draft: {
        title: gallery.title.to_s,
        bio: gallery.bio.to_s,
        matrix_contact: gallery.matrix_contact.to_s,
        page_private: gallery.page_private,
        show_contact: gallery.show_contact,
        headline: look["headline"],
        subline: look["subline"],
        banner: look["banner"],
        depth: look["depth"],
        hero: look["hero"].merge("tags" => layout.pills(look["hero"]["tags"]), "posts" => stored["hero"].to_a),
        layout: look["layout"],
        minis: look["minis"].each_with_index.map { |mini, i| mini.merge("posts" => stored["mini#{i + 1}"].to_a) },
        tuner: look["tuner"],
        # Every view the creator saved, by post: choosing a post re-applies its own.
        views: layout.views,
        harmonics: gallery.creator_gallery_harmonics.map do |harmonic|
          harmonic.slice(:id, :shown, :url, :title, :subtitle, :cta, :places, :background_post_id, :background_gradient, :focus_x, :focus_y, :zoom, :shade)
                  .merge("staff_hidden" => harmonic.staff_hidden?)
        end,
      },
      cards: draw[:harmonics],
      harmonicCap: gallery.harmonic_cap,
      # The builder's list and link checks (harmonic_model.js), the bundled
      # logos it draws, and every removal's fingerprint.
      registry: CreatorGalleryHarmonic::CONFIG,
      logos: CreatorGalleryHarmonic::CONFIG["sites"].filter_map { |site| site["logo"] }.index_with { |file| helpers.asset_pack_path("static/#{file}") },
      removed: CreatorHarmonicRemoval.pluck(:url).map { |url| CreatorHarmonicRemoval.fingerprint(url) },
      isAdmin: CurrentUser.user.is_admin?,
      slides: [*hero_slides, *draw[:minis].flat_map { |mini| mini[:slides] }, draw[:banner]].compact.uniq { |slide| slide[:id] },
      palette: palette.to_a,
      slug: gallery.slug,
      matrixId: gallery.matrix_id,
      creditPhrases: TagSetPresenter::CREDIT_PHRASES,
      liveWindow: Danbooru.config.creator_active_window.to_i,
      candidatesUrl: helpers.edit_creator_gallery_path(gallery, format: :json),
      saveUrl: helpers.creator_gallery_path(gallery),
    }
  end

  def messages
    gallery.creator_gallery_messages
  end

  # About's boxes in their fixed order, each as this viewer left it: the bio,
  # the characters and the news where the page has them, then the edit page's
  # own sections, whose html is drawn as given. A kind is the same on every
  # gallery -- an edit section's is its title's slug -- so one viewer's choice
  # for a box holds wherever that box is drawn. A box the viewer never
  # touched is open at its content's height.
  def about_boxes
    @about_boxes ||= [
      { kind: "bio", title: "Bio" },
      ({ kind: "characters", title: "Characters" } if characters.any?),
      ({ kind: "blog", title: "News" } if messages.any?),
      *panels.to_h.map { |name, html| { kind: name.parameterize, title: name, html: html } },
    ].compact.map do |box|
      state = box_states[box[:kind]] || {}
      box.merge(open: state.fetch("open", true), h: state["h"])
    end
  end

  # The creator's original characters: their standing claims (CharacterClaim),
  # one query. A member gets links to each one's posts and wiki page; a
  # signed-out visitor gets the names, because both links lead to
  # members-only pages. Never a name hidden from
  # the viewer (a quarantined name, TagQuarantine).
  def characters
    @characters ||= CharacterClaim.where(creator_gallery_id: gallery.id).standing.map(&:tag_name).reject { |name| TagQuarantine.hidden_name?(name, viewer) }.sort
  end

  def member? = MembersOnly.member?(viewer)

  # The box under the title while the contact is off names the creator and
  # nothing else (operator, 2026-11-01): their Matrix display name, else their
  # booru account's. Never the Matrix ID: a display name holding the ID is
  # the ID, and so is one that is the ID's localpart in any case -- the name a
  # homeserver gives an account that never chose one. Nil when the page knows
  # no name to give.
  def contact_name
    ids = [gallery.matrix_id, gallery.contact].map { |id| id.delete_prefix("@").downcase }
    name = avatar[:name].presence
    name = nil if name && ids.any? { |id| name.delete_prefix("@").downcase == id.split(":").first || name.downcase.include?(id) }
    name || gallery.user&.pretty_name
  end

  # matrix.to deep link opens the viewer's Matrix client to message the creator.
  def matrix_url
    "https://matrix.to/#/#{gallery.contact}"
  end
end
