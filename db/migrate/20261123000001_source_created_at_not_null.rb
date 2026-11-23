# frozen_string_literal: true

# The original date becomes the listing's default order (deploy 2 of the
# original dates; 20261122000001 added the column). A keyset needs a key on
# every row, so the column and its precision become NOT NULL, now that the
# backfill has left none empty.
#
# SET NOT NULL alone scans the whole posts table under an ACCESS EXCLUSIVE
# lock, blocking every read for the length of the scan. Instead: one CHECK
# covering both columns, added NOT VALID (instant), VALIDATEd (one scan,
# under a lock that lets reads and writes go on), then SET NOT NULL on each
# column, which Postgres proves from the valid check without scanning, and
# the check dropped.
#
# While a statement waits for its lock on posts, every later query on posts
# queues behind it. So each lock wait is short (lock_timeout) and retried,
# with a line per attempt, rather than long: the hourly tag count job
# (RegeneratePostCountsJob, :43) holds a read lock on posts for its whole
# scan, and a deploy can land in it.
#
# The remembered gallery sort "id_desc" was labelled "newest" and "id"
# "oldest"; those labels now mean the original date, so a remembered id sort
# moves with its label. The insert order stays one click away as
# "recently added" (order:id_desc).
class SourceCreatedAtNotNull < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  COLUMNS = %w[source_created_at source_created_at_precision].freeze
  CHECK = "source_created_at_not_null"
  LOCK_TIMEOUT = "2s"
  ATTEMPTS = 60
  PAUSE = 3

  def up
    execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    execute "SET statement_timeout = 0"

    unless check_exists?
      locked { execute "ALTER TABLE posts ADD CONSTRAINT #{CHECK} CHECK (#{COLUMNS.map { |c| "#{c} IS NOT NULL" }.join(" AND ")}) NOT VALID" }
    end
    locked { execute "ALTER TABLE posts VALIDATE CONSTRAINT #{CHECK}" }
    locked { execute "ALTER TABLE posts #{COLUMNS.map { |c| "ALTER COLUMN #{c} SET NOT NULL" }.join(", ")}" }
    locked { execute "ALTER TABLE posts DROP CONSTRAINT IF EXISTS #{CHECK}" }

    execute "UPDATE modulation_settings SET gallery_sort = 'posted_desc' WHERE gallery_sort = 'id_desc'"
    execute "UPDATE modulation_settings SET gallery_sort = 'posted_asc' WHERE gallery_sort IN ('id', 'id_asc')"
  ensure
    execute "RESET lock_timeout"
    execute "RESET statement_timeout"
  end

  def down
    COLUMNS.each do |column|
      execute "ALTER TABLE posts ALTER COLUMN #{column} DROP NOT NULL"
    end
  end

  private

  # Runs the block, retrying it when it could not get its lock in time.
  def locked
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::LockWaitTimeout
      holders = select_values(<<~SQL.squish).join("; ")
        SELECT a.pid || ' ' || coalesce(nullif(a.application_name, ''), a.backend_type) || ' ' || l.mode || ' for ' || date_trunc('second', now() - a.xact_start)
        FROM pg_locks l JOIN pg_stat_activity a USING (pid)
        WHERE l.relation = 'posts'::regclass AND l.granted AND a.pid <> pg_backend_pid()
      SQL
      if attempt >= ATTEMPTS
        raise "posts stayed locked through #{ATTEMPTS} attempts (held by: #{holders.presence || "none seen"}). " \
              "Nothing is half done: rerun the migration once that holder ends, or end it with SELECT pg_cancel_backend(<pid>)."
      end
      say "posts is locked (#{holders.presence || "holder gone"}); attempt #{attempt}/#{ATTEMPTS} failed, retrying in #{PAUSE}s"
      sleep PAUSE
      retry
    end
  end

  def check_exists?
    select_value("SELECT 1 FROM pg_constraint WHERE conname = #{quote(CHECK)} AND conrelid = 'posts'::regclass").present?
  end
end
