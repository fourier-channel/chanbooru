# frozen_string_literal: true

# What the landing carousel's "new" row shows. One row, edited from
# /admin/landing_setting, read by LandingShowcase.
#
# STRUCTURED, NOT A QUERY BOX. The obvious design is a text field holding the
# search, and it is a trap: an anonymous visitor may search two tags, the
# landing page runs as whoever is looking at it, and a third term does not
# narrow the row -- it empties it. An empty row is dropped silently, so the
# front page would lose its main feature with no error anywhere. The panel
# therefore offers the choices that cannot break it, and #query assembles a
# search that is two terms by construction.
class LandingSetting < ApplicationRecord
  # Matches the sampler's postSourceUrl(board, thread, post); if that host ever
  # changes, this is the other half of the pair and the row goes empty until it
  # is changed too.
  SOURCE_HOST = "https://boards.4chan.org"
  # The tag the sampler puts on archive-sourced bytes. Live captures carry
  # nothing extra, so this is excluded rather than required.
  ARCHIVE_TAG = "no_train"

  # HOW FAST THE SLIDES MOVE, in milliseconds, bounded at both ends.
  #
  # The floor is not taste. Below about a second a slide cannot be read before
  # it leaves, and the carousel's auto-advance drives a transition on every
  # step -- a value of 0 or 50 would not be a fast carousel, it would be a
  # permanent animation on the page the bare domain serves to everyone, which
  # this project has already paid for once (one infinite box-shadow animation
  # idled a surface at 45% of a core).
  # The ceiling stops a typo turning the carousel into a still image: 120000 is
  # two minutes, past which nobody would see it move at all.
  ADVANCE_MS_RANGE = (1_500..120_000)

  validates :board, format: { with: /\A[a-z0-9]{1,10}\z/,
                              message: "is a board slug like 'b', without slashes" }
  validates :label, presence: true, length: { maximum: 40 }
  validates :advance_ms, numericality: {
    only_integer: true,
    greater_than_or_equal_to: ADVANCE_MS_RANGE.min,
    less_than_or_equal_to: ADVANCE_MS_RANGE.max,
    message: "must be between #{ADVANCE_MS_RANGE.min} and #{ADVANCE_MS_RANGE.max} milliseconds",
  }

  def self.current
    first || new
  end

  # Two terms at most, and never an `order:` -- newest-first is already the
  # default, so an order term would spend one of the two and buy nothing.
  def query
    q = "source:#{SOURCE_HOST}/#{board}/*"
    q += " -#{ARCHIVE_TAG}" if fresh_only?
    q
  end

  def term_count
    query.split.length
  end
end
