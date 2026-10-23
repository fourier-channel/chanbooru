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
class CreatorGalleryComponent < ApplicationComponent
  # A miniband slot's height and narrowest width by how many share its row:
  # the prototype's ROW_H and MIN_W, as creator_gallery_model.js has them.
  ROW_H = { 1 => 340, 2 => 300, 3 => 250, 4 => 230 }.freeze
  MIN_W = { 1 => 560, 2 => 360, 3 => 250, 4 => 220 }.freeze

  attr_reader :gallery, :viewer, :draw, :avatar, :can_edit, :editing, :palette, :panels

  # @param draw [Hash] CreatorGalleryLayout#draw(viewer)
  # @param avatar [Hash] CreatorGalleryLayout#avatar(viewer): { name:, mxc:, url:, problem: }
  # @param palette [Array<Hash>] CreatorGalleryLayout#palette, in edit mode
  # @param panels [Hash{String => String}] the edit page's sections, title => HTML, in edit mode
  def initialize(gallery:, viewer:, draw:, avatar:, can_edit:, editing: false, palette: nil, panels: nil) # rubocop:disable Metrics/ParameterLists
    super
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
  # the page's.
  def monogram
    (avatar[:name].presence || title).delete_prefix("@")[0].to_s.upcase
  end

  def hero_slides
    draw[:hero][:slides]
  end

  def generals
    draw[:hero][:tags].reject { |tag| tag[:category] == "character" }
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

  # The banner's picture: the sample for an image, the preview for anything
  # else (a video's sample is the video).
  def picture(slide)
    (slide[:kind] == "image") ? slide[:src] : slide[:thumb]
  end

  # The look as CSS variables: the ground's blur and dim, the parallax's
  # strength, the banner's focus.
  def depth_style
    depth = look["depth"]
    "--cg-blur: #{depth["blur"]}px; --cg-dim: #{depth["dim"] / 100.0}; --cg-par: #{depth["parallax"] / 100.0}; --cg-y: #{look["banner"]["y"]}%"
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
        headline: look["headline"],
        subline: look["subline"],
        banner: look["banner"],
        depth: look["depth"],
        hero: look["hero"].merge("tags" => layout.pills(look["hero"]["tags"]), "posts" => stored["hero"].to_a),
        layout: look["layout"],
        minis: look["minis"].each_with_index.map { |mini, i| mini.merge("posts" => stored["mini#{i + 1}"].to_a) },
      },
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

  # The creator's original characters: their standing claims (CharacterClaim),
  # one query. A member gets links to each one's posts and wiki page; a
  # signed-out visitor, who reaches only a promoted gallery, gets the names,
  # because both links lead to members-only pages. Never a name hidden from
  # the viewer (a quarantined name, TagQuarantine).
  def characters
    @characters ||= CharacterClaim.where(creator_gallery_id: gallery.id).standing.map(&:tag_name).reject { |name| TagQuarantine.hidden_name?(name, viewer) }.sort
  end

  def member? = MembersOnly.member?(viewer)

  # matrix.to deep link opens the viewer's Matrix client to message the creator.
  def matrix_url
    "https://matrix.to/#/#{gallery.contact}"
  end
end
