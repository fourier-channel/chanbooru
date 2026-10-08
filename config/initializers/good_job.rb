GoodJob.active_record_parent_class = "ApplicationRecord"
GoodJob.retry_on_unhandled_error = false
GoodJob.preserve_job_records = true
Rails.application.config.good_job.smaller_number_is_higher_priority = true

# Called when a background job raises an unhandled exception. Only called for background jobs run with `perform_later`,
# not foreground jobs run with `perform_now`.
GoodJob.on_thread_error = lambda do |exception|
  DanbooruLogger.log(exception)
end

# Start the metrics server on http://0.0.0.0:9090/metrics when bin/good_job is run.
if GoodJob::CLI.within_exe?
  Rails.application.config.after_initialize do
    RackMetricsServer.new.start
  end
end

ActiveSupport.on_load(:good_job_application_controller) do
  # Here we are inside GoodJob::ApplicationController. This doesn't inherit from our own ApplicationController, so
  # we need to include our own authentication and exception handling methods.

  include ApplicationController::AuthenticationMethods
  include ApplicationController::ExceptionHandlingMethods
  include Pundit::Authorization

  # Needed to render the default layout for error pages.
  helper ApplicationHelper
  helper IconHelper
  helper UsersHelper

  before_action :set_current_user
  # Fork: the default-deny list (MembersOnly::ANONYMOUS_DOORS) holds here too.
  # This controller does not inherit ApplicationController, so it would
  # otherwise be the one place a signed-out viewer met upstream's answer.
  before_action { MembersOnly.admit!(self) }
  before_action :authorize_user
  rescue_from Exception, with: :rescue_exception

  # Fork: the error page in the blank layout. The default layout asks helpers
  # only ApplicationController has (modulation?, from ExperiencePreset), so
  # every refusal here rendered as a 500 instead -- measured on production
  # 2026-10-07: a signed-out GET /good_job answered 500.
  def render_error_page(status, exception = nil, **options)
    super(status, exception, **options, layout: "blank")
  end

  def authorize_user
    authorize(self, :can_view_good_job_dashboard?, policy_class: BackgroundJobPolicy)
  end

  def current_user
    CurrentUser.user
  end
end

# Fork: the dashboard's own static files (GoodJob::FrontendsController, which
# inherits ActionController::Base, not the controller above) are behind the
# default-deny list too. They are the gem's bootstrap and chart scripts and
# hold no data -- but "refused everywhere except the list" has no exception
# for harmless, or the next one will be argued the same way.
#
# to_prepare, so a reloaded class is patched again; the mark keeps a class
# that was NOT reloaded from collecting the filters twice.
Rails.application.config.to_prepare do
  next if GoodJob::FrontendsController.instance_variable_get(:@fourier_default_deny)

  GoodJob::FrontendsController.instance_variable_set(:@fourier_default_deny, true)
  GoodJob::FrontendsController.class_eval do
    include ApplicationController::AuthenticationMethods

    before_action :set_current_user
    before_action { MembersOnly.admit!(self) }
    rescue_from(ActiveRecord::RecordNotFound) { head :not_found }
  end
end
