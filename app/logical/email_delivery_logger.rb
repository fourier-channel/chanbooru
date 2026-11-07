# frozen_string_literal: true

# This is called just before an email is sent out to log information about the email.
#
# @see config/application.rb (config.action_mailer.interceptors)
# @see https://guides.rubyonrails.org/action_mailer_basics.html#intercepting-emails
class EmailDeliveryLogger
  def self.delivering_email(email)
    # Fork: not the address -- 41chan keeps none, and the log is a store too.
    DanbooruLogger.info("Delivering email #{email.subject.inspect} to #{Array(email.to).size} recipient(s)")
  end
end
