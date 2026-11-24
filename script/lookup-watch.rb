# frozen_string_literal: true

# Prints every outside name looked up in this network namespace while it runs.
# script/run-tests.sh starts it beside a test run, in the test container's
# namespace, to see what the test suite's own refusal cannot: a lookup made by
# a subprocess, which the network then stops (operator ruling 2026-11-24,
# test/test_helpers/outside_site_helper.rb).
#
#   bundle exec ruby script/lookup-watch.rb    # needs CAP_NET_RAW
#
# It prints "watching", then on the end of its input one "<count>\t<name>" a
# line. Only queries sent to Docker's resolver are read. The resolver's port is
# rewritten inside the namespace, so its address is matched and not port 53.

require "active_model"
require "addressable/uri"
require "ipaddr"
require "resolv"
require "socket"
require_relative "../app/logical/danbooru/refused_hosts"

RESOLVER = IPAddr.new("127.0.0.11").hton
PACKET_OUTGOING = 4
ETH_P_ALL = 0x0003
UDP = 17
TCP = 6

# The name an IPv4 packet looks up, or nil when it is no lookup.
def looked_up(packet)
  return unless packet.getbyte(0) >> 4 == 4 && packet.byteslice(16, 4) == RESOLVER

  payload = packet.byteslice(((packet.getbyte(0) & 15) * 4)..)
  case packet.getbyte(9)
  when UDP
    Resolv::DNS::Message.decode(payload.byteslice(8..)).question.first&.first&.to_s || "(no name)"
  when TCP
    "(a lookup over TCP)" if payload.getbyte(13) & 0x12 == 0x02 # SYN without ACK: one per connection
  end
rescue Resolv::DNS::DecodeError
  "(unreadable)"
end

# What may be printed for a name, or nil for a name that stays inside.
def shown(name)
  return if name.match?(/\A([^.(]*|localhost\.)\z/i)
  return "a refused host" if Danbooru::RefusedHosts.refused?(name)
  return name unless name.match?(/\.(in-addr|ip6)\.arpa\.?\z/i)

  labels = name.downcase.delete_suffix(".").split(".")[0...-2].reverse
  ip = IPAddr.new(name.match?(/ip6/i) ? labels.each_slice(4).map(&:join).join(":") : labels.join("."))
  "an address" unless ip.private? || ip.loopback? || ip.link_local?
rescue IPAddr::InvalidAddressError
  "an address"
end

socket = Socket.new(Socket::AF_PACKET, Socket::SOCK_DGRAM, [ETH_P_ALL].pack("n").unpack1("S"))
counts = Hash.new(0)
$stdout.sync = true
puts "watching"

stopping = false
loop do
  ready, = IO.select([socket, *(stopping ? [] : [$stdin])], nil, nil, stopping ? 0.5 : nil)
  break if ready.nil?

  stopping = true if ready.include?($stdin) && $stdin.read_nonblock(1024, exception: false).nil?
  next unless ready.include?(socket)

  packet, from = socket.recvfrom(65_535)
  next unless from.to_sockaddr.getbyte(10) == PACKET_OUTGOING # sockaddr_ll.sll_pkttype

  name = looked_up(packet) and (name = shown(name)) and counts[name] += 1
end

counts.sort.each { |name, count| puts "#{count}\t#{name}" }
