# frozen_string_literal: true

require "test_helper"

# PostVersion and PoolVersion open their own connection (the archive) to
# ENV["ARCHIVE_DATABASE_URL"] || ENV["DATABASE_URL"]. In the dev container
# DATABASE_URL is the DEV database, so under test they read the dev booru's
# versions, not the test database's: once dev held a production-shaped copy
# (2026-10-18), a test post's id met a real post's versions and the revert
# test failed on real tags. Under test they use the test database itself.
class ArchiveConnectionsTest < ActiveSupport::TestCase
  should "read post and pool versions from the test database" do
    [PostVersion, PoolVersion].each do |model|
      assert_equal ApplicationRecord.connection_db_config.database, model.connection_db_config.database, model.name
    end
  end
end
