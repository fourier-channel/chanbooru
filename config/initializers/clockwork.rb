# Define cronjobs using the clockwork gem; see https://github.com/Rykian/clockwork.
# Use `bin/rails danbooru:cron` to start the cron process.
#
# See also `app/logical/danbooru_maintenance.rb`.

module Clockwork
  # Touch a heartbeat file every minute so that health checks can tell we're alive and processing cronjobs.
  every(1.minute, "heartbeat") do
    File.write("tmp/danbooru-cron-heartbeat.txt", Time.now.utc.to_s + "\n")
  end

  every(1.hour, "hourly", at: "**:00") do
    DanbooruMaintenance.hourly
  end

  # The multi-creator carousel rows: one search per creator, off the request
  # path, on the interval the cache class declares. Was part of `hourly`;
  # moved out on 2026-09-19 because an hour was far too long for a front page
  # (operator), and thirty single-tag searches every five minutes is nothing.
  # Read from config, not from LandingShowcaseCache: an app class is not
  # loadable from an initializer and referencing one here raised NameError at
  # boot, on dev, before this ever shipped.
  every(Danbooru.config.landing_refresh_every, "landing-showcase") do
    LandingShowcaseRefreshJob.perform_later
  end

  every(1.day, "daily", at: "00:00") do
    DanbooruMaintenance.daily
  end

  every(1.week, "weekly", at: "Sunday 00:00") do
    DanbooruMaintenance.weekly
  end

  every(1.month, "monthly", at: "00:00") do
    DanbooruMaintenance.monthly
  end
end
