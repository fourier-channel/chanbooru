require "test_helper"

# Query statistics on the production database were enabled on one condition
# (operator 2026-11-12): only "if it doesn't require us to log events that can
# be traced to specific users". pg_stat_statements meets it as configured --
# one row per normalized statement, no parameters, no client address -- and
# these are the settings that keep it so. A server log of statements or
# durations would print parameters, and utility statements are kept
# un-normalized, so both are refused here.
class ChanbooruQueryStatisticsTest < ActiveSupport::TestCase
  COMPOSE = Rails.root.join("docker-compose.yaml").to_s
  DEPLOY = Rails.root.join("bin/chanbooru-deploy").to_s

  def postgres_settings
    command = Array(YAML.load_file(COMPOSE, aliases: true).dig("services", "postgres", "command"))
    assert_equal "postgres", command.first, "the postgres service must run the server: #{command.inspect}"
    command.drop(1).each_slice(2).to_h do |flag, setting|
      assert_equal "-c", flag, "postgres command: #{command.inspect}"
      setting.split("=", 2)
    end
  end

  context "the production postgres" do
    should "preload pg_stat_statements with utility statements untracked" do
      settings = postgres_settings
      assert_equal "pg_stat_statements", settings["shared_preload_libraries"]
      assert_equal "off", settings["pg_stat_statements.track_utility"]
    end

    should "run the sizing measured on the serving box, written as the server prints it" do
      sized = {
        "pg_stat_statements.max" => "10000",
        "shared_buffers" => "8GB",
        "effective_cache_size" => "32GB",
        "work_mem" => "32MB",
        "maintenance_work_mem" => "1GB",
        "random_page_cost" => "1.1",
        "track_io_timing" => "on",
        "idle_in_transaction_session_timeout" => "10min",
      }
      assert_equal sized, postgres_settings.slice(*sized.keys)
    end

    should "log no statement, duration or parameter" do
      logged = postgres_settings.keys.grep(/\A(log_statement|log_min_duration|log_duration|log_parameter|auto_explain|pg_stat_statements\.track\z)/)
      assert_empty logged, "these settings can record a user's query parameters"
    end
  end

  context "the deploy" do
    should "create the extension in the postgres database and prove both settings on the server" do
      deploy = File.read(DEPLOY)
      assert_includes deploy, "psql -U danbooru -d postgres -qAt -v ON_ERROR_STOP=1"
      assert_includes deploy, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
      assert_includes deploy, "current_setting('pg_stat_statements.track_utility')"
      assert_operator deploy.index("CREATE EXTENSION"), :>, deploy.index("front page 200"), "the booru is verified first"
    end

    should "read every declared postgres setting back from the running server" do
      deploy = File.read(DEPLOY)
      assert_includes deploy, %q{docker compose config --format json < /dev/null | python3 -c}
      assert_includes deploy, %q{["services"]["postgres"]["command"]}
      assert_includes deploy, %q{-c "SELECT current_setting('${PG_NAME}')"}
      assert_includes deploy, %q{[[ "$PG_HAVE" == "$PG_WANT" ]]}
      assert_operator deploy.index("PG_DECLARED="), :>, deploy.index("front page 200"), "the booru is verified first"
    end
  end
end
