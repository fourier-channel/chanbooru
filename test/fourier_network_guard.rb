# frozen_string_literal: true

# Fork. Refuse to run tests anywhere with a route to the outside (operator
# ruling 2026-11-24: no test run sends a request to an outside site, on any
# box). The `test` service sits on one internal Docker network, which has no
# default route; the dev container shares the dev server's network and has
# one. There is no override.
module FourierNetworkGuard
  module_function

  # @return [Array<String>] the devices a default route leaves by
  def default_routes(ipv4:, ipv6:)
    v4 = ipv4.lines.drop(1).map(&:split).select { |f| f[1] == "00000000" && f[7] == "00000000" }.map(&:first)
    # fields: destination, its prefix length, ..., device. The kernel lists an
    # unreachable default on lo in every namespace; nothing leaves by lo.
    v6 = ipv6.lines.map(&:split).select { |f| f[0] == "0" * 32 && f[1] == "00" }.map(&:last)
    (v4 + v6).uniq - ["lo"]
  end

  def check!(ipv4: "/proc/net/route", ipv6: "/proc/net/ipv6_route")
    devices = default_routes(ipv4: File.read(ipv4), ipv6: File.exist?(ipv6) ? File.read(ipv6) : "")
    return if devices.empty?

    abort(<<~MSG)
      REFUSED: this container can reach the outside (default route on #{devices.join(", ")}), and tests contact no outside site.
      fix:     bin/dev up -d test, then bash script/run-tests.sh <test file>
    MSG
  rescue SystemCallError => e
    abort("REFUSED: cannot tell whether this machine can reach the outside (#{e.message}). fix: run tests with bash script/run-tests.sh <test file>")
  end
end
