# frozen_string_literal: true

# FILLS posts.source_created_at FOR POSTS MADE BEFORE SENDERS GAVE IT
# (Post#default_source_created_at; fourier-basis docs/design/ORIGINAL_DATES.md).
#
# Three passes, run in this order so each post is written once:
#   import  -- a file of "source,time,precision" lines (CSV, no header), from
#              the archive that knows when each source was posted. Matched on
#              posts.source exactly.
#   discord -- a Discord message permalink carries its own time: the message
#              id is a snowflake whose top bits are milliseconds since
#              2015-01-01. Computed in SQL, "exact".
#   rest    -- whatever is still undated gets created_at, "added": all that is
#              known about it.
#
# A pass never lowers what is known: a post is written only when the new
# precision ranks above the one it has (exact > estimated > added > none),
# so passes can be re-run, and a later, better file can replace estimates.
#
# Writes go straight to the column (no callbacks, updated_at untouched), in
# id ranges of BATCH posts, each its own statement under a timeout, so a long
# run competes with the live site in short turns and stops where it failed.
class SourceDateBackfill
  BATCH = 5_000
  STATEMENT_TIMEOUT_MS = 60_000
  PAUSE = 0.02

  RANK = ->(column) { "(CASE #{column} WHEN 'exact' THEN 3 WHEN 'estimated' THEN 2 WHEN 'added' THEN 1 ELSE 0 END)" }

  DISCORD_PERMALINK = '^https://(ptb\.|canary\.)?discord(app)?\.com/channels/[0-9]+/[0-9]+/[0-9]+$'
  DISCORD_EPOCH_MS = 1_420_070_400_000
  # A snowflake time outside this is not a message time; such a post is left
  # for the rest pass and counted.
  DISCORD_FIRST = "2015-01-01"

  class Refused < StandardError; end

  def initialize(out: $stdout, batch: BATCH, pause: PAUSE)
    @out = out
    @batch = batch
    @pause = pause
  end

  # @param io [IO] CSV lines: source,time,precision. time is ISO 8601; give
  #   its zone (a time without one is read as UTC). precision is exact or
  #   estimated.
  # @return [Hash] lines, matched (posts whose source is in the file), written
  def import(io)
    prepare
    conn.execute("DROP TABLE IF EXISTS source_date_import")
    conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE source_date_import (
        source text NOT NULL,
        t timestamptz NOT NULL,
        precision text NOT NULL CHECK (precision IN ('exact', 'estimated'))
      )
    SQL
    # The table lives as long as this connection; the DROP above clears a
    # previous run's in the same process.
    raw = conn.raw_connection
    raw.copy_data("COPY source_date_import (source, t, precision) FROM STDIN (FORMAT csv)") do
      io.each_line { |line| raw.put_copy_data(line) }
    end
    lines = conn.select_value("SELECT count(*) FROM source_date_import").to_i
    raise Refused, "the file has no lines. Fix: give it the export, one source,time,precision per line" if lines.zero?

    dups = conn.select_values("SELECT source FROM source_date_import GROUP BY source HAVING count(*) > 1 LIMIT 3")
    raise Refused, "the file names a source more than once (#{dups.join(", ")}). Fix: one line per source, the best-known time" if dups.any?

    conn.execute("CREATE UNIQUE INDEX ON source_date_import (source)")
    conn.execute("ANALYZE source_date_import")
    say "import: #{lines} lines"

    totals = walk("import") do |lo, hi|
      conn.select_rows(<<~SQL.squish).first.map(&:to_i)
        WITH m AS (
          SELECT p.id, i.t, i.precision, #{RANK.call("p.source_created_at_precision")} < #{RANK.call("i.precision")} AS better
          FROM posts p JOIN source_date_import i ON i.source = p.source
          WHERE p.id BETWEEN #{lo} AND #{hi}
        ), u AS (
          UPDATE posts SET source_created_at = m.t AT TIME ZONE 'UTC', source_created_at_precision = m.precision
          FROM m WHERE posts.id = m.id AND m.better
          RETURNING 1
        )
        SELECT (SELECT count(*) FROM m), (SELECT count(*) FROM u)
      SQL
    end
    say "import: #{lines} lines, #{totals[0]} posts matched, #{totals[1]} written, #{lines - totals[0]} lines matched no post"
    { lines: lines, matched: totals[0], written: totals[1] }
  end

  # @return [Hash] matched (Discord permalinks), written, implausible
  def discord
    prepare
    time = "(to_timestamp(((substring(p.source from '/([0-9]+)$')::bigint >> 22) + #{DISCORD_EPOCH_MS}) / 1000.0) AT TIME ZONE 'UTC')"
    totals = walk("discord") do |lo, hi|
      conn.select_rows(<<~SQL.squish).first.map(&:to_i)
        WITH m AS (
          SELECT p.id, #{time} AS t, #{RANK.call("p.source_created_at_precision")} < 3 AS better
          FROM posts p
          WHERE p.id BETWEEN #{lo} AND #{hi} AND p.source ~ '#{DISCORD_PERMALINK}'
        ), ok AS (
          SELECT * FROM m WHERE m.t >= '#{DISCORD_FIRST}' AND m.t <= now() AT TIME ZONE 'UTC'
        ), u AS (
          UPDATE posts SET source_created_at = ok.t, source_created_at_precision = 'exact'
          FROM ok WHERE posts.id = ok.id AND ok.better
          RETURNING 1
        )
        SELECT (SELECT count(*) FROM m), (SELECT count(*) FROM u), (SELECT count(*) FROM m) - (SELECT count(*) FROM ok)
      SQL
    end
    say "discord: #{totals[0]} permalinks, #{totals[1]} written, #{totals[2]} with a time outside #{DISCORD_FIRST}..now left undated"
    { matched: totals[0], written: totals[1], implausible: totals[2] }
  end

  # @return [Hash] written
  def rest
    prepare
    totals = walk("rest") do |lo, hi|
      written = conn.update(<<~SQL.squish)
        UPDATE posts SET source_created_at = created_at, source_created_at_precision = 'added'
        WHERE id BETWEEN #{lo} AND #{hi} AND source_created_at IS NULL
      SQL
      [written]
    end
    say "rest: #{totals[0]} written"
    { written: totals[0] }
  end

  # @return [Hash{String=>Integer}] posts per precision, "none" for undated
  def report
    prepare
    counts = conn.select_rows(<<~SQL.squish).to_h { |k, v| [k, v.to_i] }
      SELECT coalesce(source_created_at_precision, 'none'), count(*) FROM posts GROUP BY 1 ORDER BY 1
    SQL
    counts.each { |k, v| say "#{k}\t#{v}" }
    counts
  end

  private

  def conn
    Post.connection
  end

  def say(line)
    @out.puts(line)
    @out.flush
  end

  # A runner carries no statement timeout (only web requests do); one batch
  # that runs away is cancelled, not waited on.
  def prepare
    conn.execute("SET statement_timeout = #{STATEMENT_TIMEOUT_MS}")
  end

  # Yields each id range; sums the counts each batch returns; prints n/N.
  def walk(name)
    max = Post.maximum(:id).to_i
    totals = nil
    lo = 1
    step = 0
    steps = (max.to_f / @batch).ceil
    while lo <= max
      hi = lo + @batch - 1
      counts = yield(lo, hi)
      totals = totals ? totals.zip(counts).map(&:sum) : counts
      step += 1
      say "#{name}: #{step}/#{steps} batches (posts to ##{[hi, max].min}) #{totals.join(" ")}" if (step % 20).zero? || hi >= max
      sleep(@pause) if @pause.positive?
      lo = hi + 1
    end
    totals || [0, 0, 0]
  end
end
