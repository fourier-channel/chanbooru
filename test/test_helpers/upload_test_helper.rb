require "resolv"

module UploadTestHelper
  extend ActiveSupport::Concern

  def create_upload!(source_or_file_path, user:, **params)
    if source_or_file_path =~ %r{\Ahttps?://}i
      skip "Skipping extractor tests as configured by the environment." if ENV["DANBOORU_SKIP_EXTRACTOR_TESTS"].to_s.truthy?
      skip "Login credentials not configured for #{source_or_file_path}" unless Source::Extractor.find(source_or_file_path).class.enabled?
      skip_if_source_host_is_dead!(source_or_file_path)
      source = { source: source_or_file_path }
    else
      file = Rack::Test::UploadedFile.new(Rails.root.join(source_or_file_path))
      source = { files: { "0" => file }}
    end

    perform_enqueued_jobs do
      post_auth uploads_path(format: :json), user, params: { upload: { **source, **params }}
    end
  end

  # Fork: these tests fetch live third-party sites, so a site whose own DNS
  # is broken turns every gate red whatever the change (baraag.net SERVFAILed
  # from 1.1.1.1 and 8.8.8.8 on 2026-11-19). Skip, naming the host, only when
  # its name does not resolve AND a control name does: if our resolver is
  # what broke, the control fails too and the test still fails loudly.
  DNS_CONTROL_HOST = "github.com"

  def skip_if_source_host_is_dead!(url)
    host = Addressable::URI.parse(url).host
    return if host.blank? || resolves?(host) || !resolves?(DNS_CONTROL_HOST)
    skip "#{host} does not resolve while #{DNS_CONTROL_HOST} does: the site's DNS is down, not ours"
  end

  def resolves?(host)
    Resolv.getaddress(host).present?
  rescue Resolv::ResolvError, Resolv::ResolvTimeout
    false
  end

  def assert_successful_upload(source_or_file_path, user: create(:user), **params)
    create_upload!(source_or_file_path, user: user, **params)

    upload = Upload.last
    assert_response 201
    assert_equal("", upload&.error.to_s)
    assert_equal("completed", upload.status)
    assert_operator(upload.media_assets.count, :>, 0)
    upload
  end

  class_methods do
    def should_upload_successfully(source)
      should "upload successfully from #{source}" do
        assert_successful_upload(source, user: create(:user))
      end
    end
  end
end
