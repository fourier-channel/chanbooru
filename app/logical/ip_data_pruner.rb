# frozen_string_literal: true

# Clears the network identity the booru stores -- IP addresses, user agents and
# the browser's session id -- once it is older than MAX_AGE. Run by
# {PruneIpDataJob}, which {DanbooruMaintenance} queues every hour, so nothing
# outlives MAX_AGE by more than an hour.
#
# Operator ruling, 2026-11-01: "7 days [of IPs] is appropriate, so long as we
# are not storing the IPs anywhere they can be accidentally leaked. 7 days of
# IPs is still a lot of sensitive data." (fourier-basis roadmap ops.61)
#
# A row that is history keeps the row and loses the identity; a row that is only
# a cache or telemetry is deleted. Each store, and the timestamp that dates it:
#
#   user_events      created_at: the event is account history, so it stays;
#                    ip_addr, user_agent, session_id and metadata are nulled.
#                    session_id is the browser's id from its session cookie,
#                    which survives logout -- the sockpuppet check matches
#                    accounts on it, so it identifies a device. metadata is
#                    written by nothing in this app; it was added upstream to
#                    hold per-request data, so whatever is in it goes too.
#                    login_session_id stays: a random id per sign-in, cleared
#                    at logout, naming the account's own login and no device.
#   users            last_ip_addr, dated by last_logged_in_at. SessionLoader
#                    rewrites the address on every request it changes on, and
#                    moves last_logged_in_at on any request an hour after the
#                    last move, so last_logged_in_at is within an hour of the
#                    address's last sighting (UserSignup's recent-IP check reads
#                    the pair the same way). A deleted account has
#                    last_logged_in_at NULL and keeps its address, so NULL
#                    counts as old.
#   api_keys         last_ip_address, dated by last_used_at: SessionLoader
#                    writes both on every API request. permitted_ip_addresses
#                    is the owner's own allowlist and is never touched.
#   ip_geolocations  a lookup cache keyed by address: deleted once its row is
#                    MAX_AGE old and no user_event younger than MAX_AGE carries
#                    its address (the event list and the sockpuppet check join
#                    on it, so a fresh event keeps its geolocation).
#   user_sessions    upstream's retired per-session table; nothing writes it.
#                    Telemetry: deleted, after unhooking the events that point
#                    at it.
#   ip_bans          never: an enforcement record a moderator wrote.
class IpDataPruner
  # The one statement of the period. Everything above is measured against it.
  MAX_AGE = 7.days

  STORES = %i[user_events users api_keys ip_geolocations user_sessions].freeze

  attr_reader :cutoff

  def initialize(now: Time.zone.now)
    @cutoff = now - MAX_AGE
  end

  # Clear every store. A store that fails does not stop the others; the first
  # error is raised once all have run, so the job still fails loudly.
  #
  # @return [Hash{Symbol => Integer}] rows changed per store
  def prune!
    errors = []
    counts = STORES.index_with do |store|
      send("prune_#{store}!")
    rescue StandardError => e
      DanbooruLogger.log(e, store: store)
      errors << e
      nil
    end

    DanbooruLogger.info("IpDataPruner: older than #{cutoff.utc.iso8601} cleared #{counts.to_json}")
    raise errors.first if errors.present?
    counts
  end

  # What prune! would change now, changing nothing. For a dry run before the
  # first live run, and for a before/after count.
  #
  # @return [Hash{Symbol => Integer}] rows that would change per store
  def pending
    {
      user_events: stale_user_events.count,
      users: stale_users.count,
      api_keys: stale_api_keys.count,
      ip_geolocations: stale_ip_geolocations.count,
      user_sessions: connection.select_value(sanitize("SELECT count(*) FROM user_sessions WHERE updated_at < ?", cutoff)).to_i,
    }
  end

  def stale_user_events
    UserEvent.where(created_at: ...cutoff).where("ip_addr IS NOT NULL OR user_agent IS NOT NULL OR session_id IS NOT NULL OR metadata IS NOT NULL")
  end

  def stale_users
    User.where.not(last_ip_addr: nil).where("last_logged_in_at IS NULL OR last_logged_in_at < ?", cutoff)
  end

  def stale_api_keys
    ApiKey.where.not(last_ip_address: nil).where("COALESCE(last_used_at, updated_at) < ?", cutoff)
  end

  def stale_ip_geolocations
    IpGeolocation.where(updated_at: ...cutoff).where(<<~SQL.squish, cutoff)
      NOT EXISTS (SELECT 1 FROM user_events WHERE user_events.ip_addr = ip_geolocations.ip_addr AND user_events.created_at >= ?)
    SQL
  end

  private

  def prune_user_events!
    stale_user_events.update_all(ip_addr: nil, user_agent: nil, session_id: nil, metadata: nil)
  end

  def prune_users!
    stale_users.update_all(last_ip_addr: nil)
  end

  def prune_api_keys!
    stale_api_keys.update_all(last_ip_address: nil)
  end

  def prune_ip_geolocations!
    stale_ip_geolocations.delete_all
  end

  # UserEvent ignores user_session_id, so this one is SQL.
  def prune_user_sessions!
    connection.transaction do
      connection.update(sanitize("UPDATE user_events SET user_session_id = NULL WHERE user_session_id IN (SELECT id FROM user_sessions WHERE updated_at < ?)", cutoff))
      connection.delete(sanitize("DELETE FROM user_sessions WHERE updated_at < ?", cutoff))
    end
  end

  def connection
    ApplicationRecord.connection
  end

  def sanitize(*sql)
    ApplicationRecord.sanitize_sql_array(sql)
  end
end
