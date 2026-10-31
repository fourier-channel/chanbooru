# frozen_string_literal: true

# THE TUNER: a creator's harmonics, one card at a time, in one of the two
# placements the creator picks (CREATOR_TUNER.md rev 3, sec 7). A, the
# Masthead Dial, sits in the header's id row across from the name: a card over
# a station scale, a needle and a knob. B, the Skywave Dial, is a card-shaped
# window in the banner with previous, pips and next. Both carry the viewer's
# Scan switch, the only motion either makes on its own.
#
# What is drawn is every card in order, the first one shown; creator_tuner.js
# tunes between them. A card is CreatorHarmonicComponent.
class CreatorTunerComponent < ApplicationComponent
  attr_reader :placement, :cards, :scan

  # @param placement [String] "A" or "B"
  # @param cards [Array<Hash>] CreatorGalleryLayout#draw's harmonics
  # @param scan [Boolean, nil] the viewer's Scan (ModulationSetting tuner_scan);
  #   nil is no opinion: on, unless the viewer's system asks for less motion
  def initialize(placement:, cards:, scan:)
    super
    @placement = placement
    @cards = cards
    @scan = scan
  end

  def letter(card)
    card[:name].to_s[0].to_s.upcase
  end

  def station(card)
    "#{card[:name]}: #{card[:title]}"
  end
end
