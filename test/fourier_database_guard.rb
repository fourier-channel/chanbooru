# frozen_string_literal: true

# Refuse to run the suite against a production database.
#
# On 2026-09-08 the whole suite ran against the LIVE booru. The danbooru
# service sets DATABASE_URL to the production database, Rails gives
# DATABASE_URL precedence over config/database.yml, and so
# `RAILS_ENV=test rails test` switched the Rails ENVIRONMENT and not the
# DATABASE. The tests read real production posts -- two failures in
# deleted_post_visibility_test were the suite finding 109 live rows tagged
# "landscape" where it expected the two it had just made. Nothing was written
# only because every test runs in a transaction that rolls back. Any test
# committing outside one would have written to the live site.
#
# Rails already knows how to detect this: db:check_protected_environments
# raises ActiveRecord::ProtectedEnvironmentError, and it DID -- during
# db:test:purge, which is a prerequisite task, so the tests ran anyway and the
# warning scrolled past. This runs the same test where it cannot be walked
# past: before the first test, aborting the process.
#
# Keyed on ar_internal_metadata.environment, NOT on the database NAME. The name
# is not the signal: CI's throwaway service container is called plain
# "danbooru" and is perfectly safe, while the production database on the
# serving box has the same name and is not. Measured: production reads
# "production"; danbooru_test and danbooru_test_0 read "test".
#
# A database with no metadata row yet is ALLOWED. That is a freshly created
# schema, which is CI's first run, and it cannot be a production database
# precisely because nothing has ever declared it one.
module FourierDatabaseGuard
  module_function

  def recorded_environment
    ActiveRecord::Base.connection.select_value(
      "SELECT value FROM ar_internal_metadata WHERE key = 'environment'",
    )
  rescue StandardError
    # No connection, no table, no database. Not something to guard against
    # here -- the suite will fail on its own terms in a moment, and saying
    # "refusing to run" would be a lie about the reason.
    nil
  end

  def protected?(environment)
    return false if environment.blank?

    ActiveRecord::Base.protected_environments.map(&:to_s).include?(environment.to_s)
  end

  def check!
    env = recorded_environment
    return unless protected?(env)

    config = ActiveRecord::Base.connection_db_config
    abort(<<~MESSAGE)

      REFUSING TO RUN: this suite is pointed at a #{env} database.

        database : #{config.database}
        host     : #{config.configuration_hash[:host] || "(default)"}
        RAILS_ENV: #{Rails.env}

      DATABASE_URL overrides config/database.yml, so setting RAILS_ENV=test is
      not enough on a box where DATABASE_URL names the production database.
      The tests would read live data, and only per-test transaction rollback
      would stand between them and writing to it.

      Repoint the connection, for example:

        export DATABASE_URL=$(printf %s "$DATABASE_URL" | sed "s#/danbooru?#/danbooru_test?#")

    MESSAGE
  end
end
