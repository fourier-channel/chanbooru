require "test_helper"

# IPs and user agents live at most 7 days, in every store including logs
# (operator, 2026-11-01). nginx's access log is bounded by size, not age, so it
# carries neither.
class NginxAccessLogTest < ActiveSupport::TestCase
  should "log no address and no user agent" do
    nginx = Rails.root.join("config/nginx.conf").read
    formats = nginx.scan(/^\s*log_format\s+\S+\s+'([^']*)'/).flatten
    logs = nginx.scan(/^\s*access_log\s+(\S+)(?:\s+(\S+?))?;/)

    assert_equal(["filtered"], logs.map(&:last), "every access_log must use the filtered format")
    assert_equal(1, formats.size)
    %w[$remote_addr $binary_remote_addr $realip_remote_addr $http_x_forwarded_for $proxy_add_x_forwarded_for $http_x_real_ip $http_cf_connecting_ip $http_user_agent].each do |field|
      assert_not_includes(formats.first, field)
    end
  end
end
