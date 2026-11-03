require "test_helper"

# bin/good_job adds its own logger on stdout at DEBUG unless told not to, and at
# DEBUG GoodJob logs every LISTEN/NOTIFY payload it receives: ~3,400 lines an
# hour on the serving box (2026-11-03), and nothing else in the app logs below
# its configured level. Errors still reach Rails.logger (GoodJob.logger).
class GoodJobLoggingTest < ActiveSupport::TestCase
  should "not add the CLI's stdout logger" do
    assert_equal(false, GoodJob::CLI.log_to_stdout)
  end
end
