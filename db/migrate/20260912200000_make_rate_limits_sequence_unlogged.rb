# frozen_string_literal: true

# `rate_limits` is UNLOGGED on purpose, upstream's choice: its rows are
# throttle counters that a PruneRateLimitsJob deletes once they pass an hour,
# and losing them to a crash costs nothing. Unlogged means Postgres skips the
# write-ahead log for them, which makes every update cheaper.
#
# The table is unlogged in production. Its id sequence is not. So id allocation
# still writes WAL for a table whose contents are deliberately not crash-safe,
# which buys nothing -- when the table is truncated on recovery, a surviving
# sequence value is meaningless.
#
# Measured 2026-09-12: 4,310 rows, 2,308 of them written in the last hour, and
# `rate_limits_id_seq` is the ONLY sequence in the whole database whose
# persistence disagrees with its table. One stray, not a pattern.
#
# Checked before changing it: nothing depends on these ids. There are no
# foreign keys onto `rate_limits` and nothing joins to it. RateLimit is touched
# in exactly three places -- RateLimiter writes it, PruneRateLimitsJob deletes
# from it, and a read-only index page shows the owner their own rows. No caller
# needs an id to be stable, unique across a restart, or monotonic.
#
# ALTER SEQUENCE ... SET UNLOGGED needs PostgreSQL 15 or newer. Production is
# 16.1, so this is supported; on an older server it would fail loudly rather
# than silently, which is the behaviour we want.
class MakeRateLimitsSequenceUnlogged < ActiveRecord::Migration[7.1]
  def up
    execute "ALTER SEQUENCE rate_limits_id_seq SET UNLOGGED"
  end

  def down
    execute "ALTER SEQUENCE rate_limits_id_seq SET LOGGED"
  end
end
