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

  validates :board, format: { with: /\A[a-z0-9]{1,10}\z/,
                              message: "is a board slug like 'b', without slashes" }
  validates :label, presence: true, length: { maximum: 40 }

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
