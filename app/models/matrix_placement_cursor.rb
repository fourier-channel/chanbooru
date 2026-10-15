# frozen_string_literal: true

# How far each of fourier-auth's two placement readers has pushed (GATE 3 FOR
# POSTS): `live` follows Synapse's event order (stream_ordering) from the
# head, `sweep` walks all of history on a slow lap and catches what leaves no
# event. The booru keeps the cursors so fourier-auth resumes from what was
# RECORDED, never from what it believes it sent. A cursor only moves up,
# except that a sweep push from the start of history (from = 0) begins a new
# lap (MatrixPlacements).
class MatrixPlacementCursor < ApplicationRecord
  STREAMS = %w[live sweep].freeze

  # { live:, sweep:, lap_started_at: } as the placements answer carries it
  # (GATE3_CONTRACTS.md): every field an integer or null -- null before the
  # first push, since 0 is a real stream position -- and lap_started_at in
  # epoch milliseconds.
  def self.answer
    rows = where(stream: STREAMS).index_by(&:stream)
    {
      live: rows["live"]&.position,
      sweep: rows["sweep"]&.position,
      lap_started_at: rows["sweep"]&.lap_ms,
    }
  end

  # lap_started_at as the epoch milliseconds the reader sent, or nil.
  def lap_ms
    lap_started_at && (lap_started_at.to_r * 1000).round
  end
end
