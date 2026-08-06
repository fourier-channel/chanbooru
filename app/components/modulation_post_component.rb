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
      helpers.number_to_human_size(post.file_size),
      ".#{post.file_ext}",
      post.created_at.strftime("%Y-%m-%d"),
      "@#{post.uploader.name}",
    ]
  end

  def media_gated?
    post.source.to_s.start_with?("mxc://")
  end
end
