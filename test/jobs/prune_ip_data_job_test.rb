require "test_helper"

# Operator ruling, 2026-11-01: IP addresses and user agents live 7 days.
# IpDataPruner names each store and the timestamp that dates it.
class PruneIpDataJobTest < ActiveJob::TestCase
  def old
    IpDataPruner::MAX_AGE.ago - 1.day
  end

  def fresh
    IpDataPruner::MAX_AGE.ago + 1.day
  end

  def insert_user_session(at)
    ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([
      "INSERT INTO user_sessions (created_at, updated_at, ip_addr, session_id, user_agent) VALUES (?, ?, '203.0.113.9', 'sess', 'Agent/1') RETURNING id", at, at,
    ]))
  end

  context "PruneIpDataJob" do
    should "state the period once, as the operator ruled it" do
      assert_equal(7.days, IpDataPruner::MAX_AGE)
    end

    should "be queued by the hourly maintenance" do
      assert_enqueued_with(job: PruneIpDataJob) { DanbooruMaintenance.hourly }
    end

    context "on user_events" do
      setup do
        @old_event = create(:user_event, created_at: old, metadata: { "ua" => "x" })
        @fresh_event = create(:user_event, created_at: fresh, metadata: { "ua" => "y" })
        @fresh_snapshot = @fresh_event.reload.attributes
        PruneIpDataJob.perform_now
      end

      should "scrub the network identity of an old event and keep the event" do
        @old_event.reload
        assert_nil(@old_event.ip_addr)
        assert_nil(@old_event.user_agent)
        assert_nil(@old_event.session_id)
        assert_nil(@old_event.metadata)
        assert_equal("login", @old_event.category)
        assert_not_nil(@old_event.user_id)
        assert_not_nil(@old_event.login_session_id)
      end

      should "leave a fresh event untouched" do
        assert_equal(@fresh_snapshot, @fresh_event.reload.attributes)
        assert_not_nil(@fresh_event.ip_addr)
      end
    end

    context "on users.last_ip_addr" do
      setup do
        @old_user = create(:user, last_ip_addr: "203.0.113.1", last_logged_in_at: old)
        @fresh_user = create(:user, last_ip_addr: "203.0.113.2", last_logged_in_at: fresh)
        @deleted_user = create(:user, last_ip_addr: "203.0.113.3", last_logged_in_at: nil)
        PruneIpDataJob.perform_now
      end

      should "clear an address last seen before the period, and a deleted account's" do
        assert_nil(@old_user.reload.last_ip_addr)
        assert_nil(@deleted_user.reload.last_ip_addr)
      end

      should "keep an address seen within the period" do
        assert_equal("203.0.113.2", @fresh_user.reload.last_ip_addr.to_s)
      end
    end

    context "on api_keys" do
      setup do
        @old_key = create(:api_key, last_ip_address: "203.0.113.4", last_used_at: old, permitted_ip_addresses: ["198.51.100.0/24"])
        @fresh_key = create(:api_key, last_ip_address: "203.0.113.5", last_used_at: fresh)
        PruneIpDataJob.perform_now
      end

      should "clear the last address of a key last used before the period, and keep its allowlist" do
        @old_key.reload
        assert_nil(@old_key.last_ip_address)
        assert_equal(["198.51.100.0/24"], @old_key.permitted_ip_addresses.map(&:to_s))
      end

      should "keep the last address of a key used within the period" do
        assert_equal("203.0.113.5", @fresh_key.reload.last_ip_address.to_s)
      end
    end

    context "on ip_geolocations" do
      setup do
        @orphan = create(:ip_geolocation, updated_at: old, created_at: old)
        @in_use = create(:ip_geolocation, updated_at: old, created_at: old)
        create(:user_event, created_at: fresh, ip_addr: @in_use.ip_addr.to_s)
        @recent = create(:ip_geolocation)
        PruneIpDataJob.perform_now
      end

      should "delete an old lookup no fresh event holds" do
        assert_not(IpGeolocation.exists?(@orphan.id))
      end

      should "keep a lookup a fresh event still holds, and a fresh lookup" do
        assert(IpGeolocation.exists?(@in_use.id))
        assert(IpGeolocation.exists?(@recent.id))
      end
    end

    context "on user_sessions" do
      should "delete an old row, unhooking its events, and keep a fresh one" do
        old_id = insert_user_session(old)
        fresh_id = insert_user_session(fresh)
        event = create(:user_event)
        ApplicationRecord.connection.update("UPDATE user_events SET user_session_id = #{old_id.to_i} WHERE id = #{event.id.to_i}")

        PruneIpDataJob.perform_now

        assert_equal([fresh_id], ApplicationRecord.connection.select_values("SELECT id FROM user_sessions"))
        assert_nil(ApplicationRecord.connection.select_value("SELECT user_session_id FROM user_events WHERE id = #{event.id.to_i}"))
      end
    end

    context "on ip_bans" do
      should "touch nothing" do
        ban = create(:ip_ban, ip_addr: "203.0.113.0/24", created_at: 1.year.ago, updated_at: 1.year.ago)
        before = ban.reload.attributes

        PruneIpDataJob.perform_now

        assert_equal(1, IpBan.count)
        assert_equal(before, ban.reload.attributes)
      end
    end

    should "report what it would change, and change nothing doing so" do
      create(:user_event, created_at: old)
      create(:user, last_ip_addr: "203.0.113.6", last_logged_in_at: old)

      pending = IpDataPruner.new.pending
      assert_equal(1, pending[:user_events])
      assert_equal(1, pending[:users])
      assert_equal(pending, IpDataPruner.new.pending)

      PruneIpDataJob.perform_now
      assert_equal({ user_events: 0, users: 0, api_keys: 0, ip_geolocations: 0, user_sessions: 0 }, IpDataPruner.new.pending)
    end
  end
end
