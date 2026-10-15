# frozen_string_literal: true

# THE PLACEMENTS FEED, the receiving half (GATE 3 FOR POSTS, fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md, piece D for piece A). fourier-auth walks
# Synapse's events from a cursor -- `live` from the head, `sweep` over all of
# history on a slow lap -- and for every image an event touches PUSHES its own
# answer for that image: uploader, site asset or not, and the rooms it counts
# in. It arrives on POST /fourier_jail/release.json as
#
#   {"placements": {"stream": "live"|"sweep", "from": N, "to": N,
#                   "snapshot": {"head": N, "at": "<ISO 8601>"},
#                   "mxcs": [{"mxc", "uploader", "site_asset", "rooms": [...],
#                             "newest_ordering"}],
#                   "skipped": [...]}}
#
# and is answered {"cursor": {"live", "sweep", "lap_started_at"}, "applied",
# "stale", "rejected", "rejections", "skipped"}.
#
# The rules, each paid for at least twice in sampling:
#
#   - PER IMAGE, NEWER REPLACES. An mxc's row is written only when the push's
#     snapshot (head, at) is newer than the one it holds, and then REPLACES
#     it -- rooms, uploader, site asset -- so a redaction or a room the image
#     left lands. An older or equal snapshot is `stale` and changes nothing:
#     a slow sweep can never undo what the live reader recorded since.
#   - THE CURSOR ONLY MOVES UP, in the same transaction as the rows it
#     covers: fourier-auth resumes from what was recorded, never from what it
#     sent. The one way down is a new sweep lap: every sweep page carries
#     "lap" (the lap's start, epoch ms); a push whose lap is NEWER than the
#     stored lap_started_at SETS the sweep cursor to its `to`; the same lap
#     only advances; an older lap is stale (GATE3_CONTRACTS.md, dcfb4de).
#   - PER-ITEM ISOLATION. One malformed or failing mxc is counted in
#     `rejected` with its reason, inside its own savepoint, and never stops
#     the batch or holds the cursor back.
#   - Every post mapped to an mxc that was written is recomputed
#     (PostMxc.recompute_room_ids!) before the transaction commits.
class MatrixPlacements
  # The most mxcs one push may carry; the reader sends more pushes.
  MAX_MXCS = 1000
  # The most rooms one mxc may list.
  MAX_ROOMS = 20_000
  # The most rejections named in an answer (all are counted).
  MAX_REJECTIONS_NAMED = 50

  # The whole push is refused (422), with what to send instead.
  class Invalid < StandardError; end

  def self.apply!(payload)
    new(payload).apply!
  end

  def initialize(payload)
    @payload = payload
  end

  def apply!
    envelope = validate_envelope!
    items, rejections = validate_items(envelope[:mxcs])
    applied = []
    stale = 0

    ApplicationRecord.transaction do
      interned = MatrixRoom.intern!(items.flat_map { |item| item[:rooms] })
      items.sort_by { |item| item[:mxc] }.each do |item|
        written = ApplicationRecord.transaction(requires_new: true) { upsert!(item, interned, envelope[:snapshot]) }.present?
        written ? applied << item[:mxc] : stale += 1
      rescue ActiveRecord::ActiveRecordError => e
        rejections << { mxc: item[:mxc], reason: "not recorded: #{e.class}: #{e.message.truncate(200)}" }
      end

      PostMxc.recompute_room_ids!(PostMxc.where(mxc: applied).distinct.pluck(:post_id)) if applied.any?
      advance_cursor!(envelope)
    end

    if rejections.any? || envelope[:skipped].positive?
      Rails.logger.warn("gate3 placements (#{envelope[:stream]} #{envelope[:from]}..#{envelope[:to]}): #{rejections.size} rejected, #{envelope[:skipped]} skipped by fourier-auth; first rejection: #{rejections.first&.dig(:reason)}")
    end

    {
      cursor: MatrixPlacementCursor.answer,
      applied: applied.size,
      stale: stale,
      rejected: rejections.size,
      rejections: rejections.first(MAX_REJECTIONS_NAMED),
      skipped: envelope[:skipped],
    }
  end

  private

  attr_reader :payload

  def validate_envelope!
    raise Invalid, "placements must be an object: {\"stream\", \"from\", \"to\", \"snapshot\": {\"head\", \"at\"}, \"mxcs\": [...]}" unless payload.is_a?(Hash)

    stream = payload["stream"].to_s
    raise Invalid, "placements.stream must be one of #{MatrixPlacementCursor::STREAMS.join(", ")}, got #{payload["stream"].inspect}" unless stream.in?(MatrixPlacementCursor::STREAMS)

    to = position(payload["to"])
    raise Invalid, "placements.to must be the stream position this push covers up to (an integer; the sweep's tail is negative), got #{payload["to"].inspect}" if to.nil?

    from = payload["from"].nil? ? nil : position(payload["from"])
    if (payload.key?("from") && !payload["from"].nil? && from.nil?) || (from && from > to)
      raise Invalid, "placements.from must be an integer no greater than to (#{to}), got #{payload["from"].inspect}"
    end

    # "lap": the sweep lap's start, epoch ms, the same on every page of a lap;
    # on sweep pages only (GATE3_CONTRACTS.md).
    lap = payload["lap"].nil? ? nil : position(payload["lap"])
    raise Invalid, "placements.lap must be the sweep lap's start in epoch milliseconds, the same on every page of the lap, got #{payload["lap"].inspect}" if stream == "sweep" && (lap.nil? || lap <= 0)
    raise Invalid, "placements.lap belongs on sweep pages only, not #{stream}" if stream != "sweep" && !payload["lap"].nil?

    snapshot = payload["snapshot"]
    head = snapshot.is_a?(Hash) ? position(snapshot["head"]) : nil
    at = snapshot.is_a?(Hash) ? time(snapshot["at"]) : nil
    if head.nil? || at.nil?
      raise Invalid, "placements.snapshot must be {\"head\": <Synapse stream position the answers were read at>, \"at\": <epoch milliseconds>}, got #{snapshot.inspect.truncate(120)}"
    end

    mxcs = payload["mxcs"]
    raise Invalid, "placements.mxcs must be a list (empty is fine), got #{mxcs.class}" unless mxcs.is_a?(Array)
    raise Invalid, "placements.mxcs lists #{mxcs.size} images; send at most #{MAX_MXCS} per push" if mxcs.size > MAX_MXCS

    skipped = payload["skipped"]
    raise Invalid, "placements.skipped must be a list when sent, got #{skipped.class}" unless skipped.nil? || skipped.is_a?(Array)

    { stream: stream, from: from, to: to, lap: lap, snapshot: { head: head, at: at }, mxcs: mxcs, skipped: Array(skipped).size }
  end

  # [valid items, rejections]: a malformed item is named, never fatal.
  def validate_items(mxcs)
    rejections = []
    items = mxcs.each_with_index.filter_map do |raw, index|
      reason = item_problem(raw)
      if reason
        rejections << { mxc: raw.is_a?(Hash) ? raw["mxc"].to_s.truncate(300) : nil, index: index, reason: reason }
        next
      end

      {
        mxc: raw["mxc"],
        uploader: raw["uploader"].to_s,
        site_asset: raw["site_asset"],
        rooms: raw["rooms"].uniq,
        newest_ordering: raw["newest_ordering"].nil? ? nil : position(raw["newest_ordering"]),
      }
    end
    [items, rejections]
  end

  def item_problem(raw)
    return "an item must be an object {\"mxc\", \"uploader\", \"site_asset\", \"rooms\", \"newest_ordering\"}" unless raw.is_a?(Hash)
    return "mxc must be mxc://<server>/<media id>" unless raw["mxc"].is_a?(String) && raw["mxc"].match?(MatrixMedia::MXC)
    return "uploader must be the uploader's Matrix id as a string (empty when unknown)" unless raw["uploader"].nil? || (raw["uploader"].is_a?(String) && raw["uploader"].size <= 255)
    return "site_asset must be true or false" unless raw["site_asset"].in?([true, false])

    rooms = raw["rooms"]
    return "rooms must be a list of Matrix room ids (empty when it counts in none)" unless rooms.is_a?(Array) && rooms.all? { |room| room.is_a?(String) && room.match?(MatrixRoom::ROOM_ID) }
    return "rooms lists #{rooms.size} rooms; at most #{MAX_ROOMS}" if rooms.size > MAX_ROOMS
    return "newest_ordering must be an integer when sent" unless raw["newest_ordering"].nil? || position(raw["newest_ordering"])

    nil
  end

  # The row's id when it was written -- inserted, or replaced by a newer
  # snapshot -- and nil when the stored snapshot is as new or newer.
  def upsert!(item, interned, snapshot)
    rooms = item[:rooms].map { |room| interned.fetch(room) }.uniq.sort
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, item[:mxc], item[:uploader], item[:site_asset], "{#{rooms.join(",")}}", snapshot[:head], snapshot[:at], item[:newest_ordering]])
      INSERT INTO matrix_media (mxc, uploader, site_asset, room_ids, snapshot_head, snapshot_at, newest_ordering, created_at, updated_at)
      VALUES (?, ?, ?, ?::integer[], ?, ?, ?, now(), now())
      ON CONFLICT (mxc) DO UPDATE SET
        uploader = EXCLUDED.uploader, site_asset = EXCLUDED.site_asset, room_ids = EXCLUDED.room_ids,
        snapshot_head = EXCLUDED.snapshot_head, snapshot_at = EXCLUDED.snapshot_at,
        newest_ordering = EXCLUDED.newest_ordering, updated_at = now()
      WHERE (matrix_media.snapshot_head, matrix_media.snapshot_at) < (EXCLUDED.snapshot_head, EXCLUDED.snapshot_at)
      RETURNING id
    SQL
    ActiveRecord::Base.connection.select_value(sql)
  end

  def advance_cursor!(envelope)
    now = Time.zone.now
    MatrixPlacementCursor.insert_all([{ stream: envelope[:stream], position: 0, created_at: now, updated_at: now }], unique_by: :stream)
    cursor = MatrixPlacementCursor.lock.find_by!(stream: envelope[:stream])
    if envelope[:stream] == "sweep"
      stored = cursor.lap_ms
      if stored.nil? || envelope[:lap] > stored
        # A NEWER lap starts the sweep again: SET, the one way down.
        cursor.update!(position: envelope[:to], lap_started_at: Time.zone.at(Rational(envelope[:lap], 1000)))
      elsif envelope[:lap] == stored && envelope[:to] > cursor.position
        cursor.update!(position: envelope[:to])
      end
      # An OLDER lap is stale: its cursor never moves this one.
    elsif envelope[:to] > cursor.position
      cursor.update!(position: envelope[:to])
    end
  end

  # A Synapse stream position: any integer -- backfilled history sits at
  # NEGATIVE stream_ordering, and the sweep starts at that tail.
  def position(value)
    case value
    when Integer then value
    when String then value.match?(/\A-?\d{1,19}\z/) ? value.to_i : nil
    end
  end

  # The contract sends epoch milliseconds (GATE3_CONTRACTS.md); an ISO 8601
  # string is accepted too.
  def time(value)
    case value
    when Integer then Time.zone.at(value / 1000.0)
    when String then value.match?(/\A\d{10,16}\z/) ? Time.zone.at(value.to_i / 1000.0) : Time.iso8601(value)
    end
  rescue ArgumentError
    nil
  end
end
