# Define cronjobs using the clockwork gem; see https://github.com/Rykian/clockwork.
# Use `bin/rails danbooru:cron` to start the cron process.
#
# See also `app/logical/danbooru_maintenance.rb`.

module Clockwork
  # Touch a heartbeat file every minute so that health checks can tell we're alive and processing cronjobs.
  every(1.minute, "heartbeat") do
    File.write("tmp/danbooru-cron-heartbeat.txt", Time.now.utc.to_s + "\n")
  end

  # Fork: every block that runs app code runs inside the Rails reloader, as a
  # job or a request does. The cron process lives for days and is never a
  # server, so without it a dev box keeps calling the code it booted with:
  # vesper's cron, up 17 h, never queued PruneIpDataJob after ad69b11eb added
  # it to `hourly`, and kept 13-day-old IPs (2026-11-01). In production code
  # never changes under a running process, so this is the executor only.
  every(1.hour, "hourly", at: "**:00") do
    Rails.application.reloader.wrap { DanbooruMaintenance.hourly }
  end

  # Fork: the tag-count rebuild, hourly but OFF the hour. It aggregates the
  # whole posts table (80-132 s a run on production) and ran at :00 with the
  # other hourly jobs, sampling's burst of new posts and the 5-minute timers;
  # in the incident of 2026-10-19 (fourier-auth's visibility asks timing out,
  # images refused with a 503) its 05:00 run was the longest in 8 hours.
  # :43 is clear of :00 and :30, of the deployment's own clock-aligned
  # timers (read 2026-10-19: every five minutes on 0 and 2 past, and a few
  # daily ones in the first quarter of an hour) and of everything else here.
  every(1.hour, "regenerate-post-counts", at: "**:43") do
    Rails.application.reloader.wrap { DanbooruMaintenance.queue(RegeneratePostCountsJob) }
  end

  # The multi-creator carousel rows: one search per creator, off the request
  # path, on the interval the cache class declares. Was part of `hourly`;
  # moved out on 2026-09-19 because an hour was far too long for a front page
  # (operator), and thirty single-tag searches every five minutes is nothing.
  # Read from config, not from LandingShowcaseCache: an app class is not
  # loadable from an initializer and referencing one here raised NameError at
  # boot, on dev, before this ever shipped. (Inside the block is fine: it runs
  # at each tick, long after boot.)
  #
  # The Blog row's read of the blog index rides the same tick as a separate
  # job, so the carousel has one clock and a blog outage cannot stop the
  # creator rows refreshing.
  every(Danbooru.config.landing_refresh_every, "landing-showcase") do
    Rails.application.reloader.wrap do
      LandingShowcaseRefreshJob.perform_later
      LandingBlogRefreshJob.perform_later
    end
  end

  every(1.day, "daily", at: "00:00") do
    Rails.application.reloader.wrap { DanbooruMaintenance.daily }
  end

  every(1.week, "weekly", at: "Sunday 00:00") do
    Rails.application.reloader.wrap { DanbooruMaintenance.weekly }
  end

  every(1.month, "monthly", at: "00:00") do
    Rails.application.reloader.wrap { DanbooruMaintenance.monthly }
  end
end
