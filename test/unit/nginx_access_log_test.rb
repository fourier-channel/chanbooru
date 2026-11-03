require "test_helper"

# IPs and user agents live at most 7 days, in every store including logs
# (operator, 2026-11-01). nginx's access log is bounded by size, not age, so it
# carries neither.
class NginxAccessLogTest < ActiveSupport::TestCase
  should "log no address and no user agent" do
    nginx = Rails.root.join("config/nginx.conf").read
    formats = nginx.scan(/^\s*log_format\s+\S+\s+'([^']*)'/).flatten
    logs = nginx.scan(/^\s*access_log\s+(\S+)(?:\s+([^\s;]+))?(?:\s+if=\S+?)?;/)

    assert_equal(["filtered"], logs.map(&:last), "every access_log must use the filtered format")
    assert_equal(1, formats.size)
    %w[$remote_addr $binary_remote_addr $realip_remote_addr $http_x_forwarded_for $proxy_add_x_forwarded_for $http_x_real_ip $http_cf_connecting_ip $http_user_agent].each do |field|
      assert_not_includes(formats.first, field)
    end
  end

  # The pipeline's own API traffic was 85% of this log (~26,000 lines an hour on
  # the serving box, 2026-11-03); a request signed with an API key that
  # succeeded is left out, and a refused or failed one still logs.
  should "leave out only the successful requests an API key makes" do
    nginx = Rails.root.join("config/nginx.conf").read
    map = nginx[/^\s*map\s+"\$remote_user:\$status"\s+\$access_loggable\s*\{(.*?)\}/m, 1]
    assert_not_nil(map, "nginx.conf must map \"$remote_user:$status\" to $access_loggable")
    assert_match(%r{^\s*access_log\s+/dev/stdout\s+filtered\s+if=\$access_loggable;}, nginx)

    rules = map.scan(/^\s*"~([^"]+)"\s+(\d);/).map { |pattern, value| [Regexp.new(pattern), value] }
    loggable = ->(user_status) { rules.find { |re, _| re.match?(user_status) }&.last || "1" }

    assert_equal("0", loggable.call("sample:200"))
    assert_equal("0", loggable.call("sample:302"))
    assert_equal("1", loggable.call("sample:404"))
    assert_equal("1", loggable.call("sample:500"))
    assert_equal("1", loggable.call(":200"))
    assert_equal("1", loggable.call(":500"))
  end
end
