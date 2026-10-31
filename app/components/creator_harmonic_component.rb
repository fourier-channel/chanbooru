# frozen_string_literal: true

# A HARMONIC as the Tuner draws it (fourier-basis docs/design/CREATOR_TUNER.md
# rev 3, sec 2): the whole card one anchor out, to the host it names. Its
# background is the post the viewer is drawn, or a gradient, or Ground; its
# words sit in the places the creator gave them, in rows that share their
# width (sec 2.3).
#
# The tiers (sec 2.5) are drawn by container query, never by script: the card
# carries a FULL safe area and a COMPACT one (the mark, the title and the
# host), and the card's own width shows one of them; under 180 px the mark
# keeps only its icon. creator_tuner.js#harmonicCard draws the same card from
# the same hash for the builder.
class CreatorHarmonicComponent < ApplicationComponent
  TIERS = { "full" => %w[mark title subtitle button host], "compact" => %w[mark title host] }.freeze

  attr_reader :card, :hidden

  # @param card [Hash] one of CreatorGalleryLayout#draw's harmonics
  # @param hidden [Boolean] not the card the Tuner shows: out of the tab order
  #   and the accessibility tree (sec 7.A)
  def initialize(card:, hidden: false)
    super
    @card = card
    @hidden = hidden
  end

  # One tier's rows, top to bottom: [[row, thirds, [[column, elements], ...]], ...].
  # Elements sharing a place stack in the fixed order; a row holding a centre
  # and a side place splits into thirds so the centre stays centred, any other
  # row shares its width by content (sec 2.3).
  def rows(tier)
    drawn = TIERS[tier].select { |element| drawn?(element) }
    %w[t m b].map do |row|
      columns = %w[l c r].index_with { |column| drawn.select { |element| card[:places][element] == "#{row}#{column}" } }
      occupied = columns.keys.select { |column| columns[column].any? }
      shown = (columns["c"].any? && occupied.size > 1) ? %w[l c r] : occupied
      [row, shown.size == 3, shown.map { |column| [column, columns[column]] }]
    end
  end

  def drawn?(element)
    case element
    when "mark" then card[:places]["mark"].present?
    when "subtitle" then card[:subtitle].present?
    when "button" then card[:cta_label].present?
    else true
    end
  end

  def letter
    card[:name].to_s[0].to_s.upcase
  end

  # Over a picture the shade never drops under its floor while words sit on
  # it; a gradient is dark enough by construction (sec 2.6).
  def shade
    picture = card[:picture]
    picture ? [picture[:shade], CreatorGalleryHarmonic::LIMITS["shade_floor"]].max / 100.0 : 0
  end

  def picture_style
    picture = card[:picture]
    "object-position: #{picture[:focus_x]}% #{picture[:focus_y]}%; transform-origin: #{picture[:focus_x]}% #{picture[:focus_y]}%; transform: scale(#{picture[:zoom] / 100.0})"
  end

  # What the blacklist matches the picture on; the picture alone, so a
  # blacklisted background hides and the link stays.
  def marks
    card[:picture].slice(:id, :tags, :rating, :flags, :score, :uploader_id)
  end

  def classes
    ["cg-hm", ("cg-hm--off" unless card[:counts] && card[:shown]), ("cg-hm--amber" if card[:notice])]
  end
end
