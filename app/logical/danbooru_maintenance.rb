# frozen_string_literal: true

module DanbooruMaintenance
  module_function

  def hourly
    queue PrunePostsJob
    queue PruneRateLimitsJob
    queue RegeneratePostCountsJob
    queue PruneUploadsJob
    queue PruneJobsJob
    queue PruneBansJob
    # LandingShowcaseRefreshJob is NOT here any more: it runs on its own
    # clock in config/initializers/clockwork.rb, every
    # LandingShowcaseCache::REFRESH_EVERY, because hourly was far too long for
    # the front page (operator, 2026-09-19).
    # queue AmcheckDatabaseJob
  end

  def daily
    queue PrunePostDisapprovalsJob
    queue PruneBulkUpdateRequestsJob
    queue BigqueryExportAllJob
    queue VacuumDatabaseJob
  end

  def weekly
    queue RetireTagRelationshipsJob
    queue DmailInactiveApproversJob
  end

  def monthly
    queue PruneApproversJob
  end

  def queue(job)
    Rails.logger.level = :info if !Rails.env.local?
    DanbooruLogger.info("Queueing #{job.name}")
    ApplicationRecord.connection.verify!
    job.perform_later
  rescue Exception => e # rubocop:disable Lint/RescueException
    DanbooruLogger.log(e)
    raise e if Rails.env.test?
  end
end
