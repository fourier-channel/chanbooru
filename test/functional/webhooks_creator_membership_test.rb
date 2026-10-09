# frozen_string_literal: true

require "test_helper"

# The signed path a sign-up provider would call (design CREATOR_VISIBILITY Q5,
# ruled 2026-10-07: "built alongside, unused"; CreatorMembershipWebhook,
# 2026-10-09). The signature is what is under test, so the requests are made
# signed in as a plain member, which is how they pass the members-only rule:
# the action is deliberately not an anonymous door until a provider exists.
# The secret is stubbed -- the TEST command mounts the real local config.
class WebhooksCreatorMembershipTest < ActionDispatch::IntegrationTest
  SECRET = "test-secret-for-creator-membership"

  def signature(body, at: Time.now.to_i, secret: SECRET)
    "t=#{at},v1=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{at}.#{body}")}"
  end

  def deliver(payload, header: :sign, body: nil)
    body ||= payload.to_json
    headers = { "Content-Type" => "application/json" }
    headers[CreatorMembershipWebhook::HEADER] = (header == :sign) ? signature(body) : header if header
    login_as(@caller)
    post receive_webhooks_path(source: "creator_membership"), params: body, headers: headers
  end

  def event(**overrides)
    { event_id: SecureRandom.uuid, action: "add", creator: "@maple:41chan.net", group: "41chan_maple_tier_1", user_id: @fan.id, expires_at: 30.days.from_now.utc.iso8601 }.merge(overrides)
  end

  setup do
    CreatorPrefixes.reset!
    Danbooru.config.stubs(:creator_membership_webhook_secret).returns(SECRET)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @caller = create(:user)
    @maple = create(:user)
    @fan = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
  end

  should "answer 503 with the remedy while no secret is set" do
    Danbooru.config.stubs(:creator_membership_webhook_secret).returns(nil)
    deliver(event)

    assert_response 503
    assert_equal("creator membership automation is not configured: set creator_membership_webhook_secret", response.parsed_body["error"])
    assert_equal(0, CreatorGroupMembership.count)
  end

  should "refuse a bad signature, a tampered body, a missing header and a stale timestamp" do
    payload = event
    body = payload.to_json
    {
      "a bad signature" => [signature(body, secret: "wrong"), body],
      "a tampered body" => [signature(body), event(event_id: payload[:event_id], user_id: @maple.id).to_json],
      "no header" => [nil, body],
      "a 301 s old timestamp" => [signature(body, at: Time.now.to_i - 301), body],
    }.each do |why, (header, sent)|
      deliver(nil, header: header, body: sent)

      assert_response(401, why)
      assert(response.parsed_body["error"].present?, why)
    end
    assert_equal(0, CreatorGroupMembership.count)
  end

  should "add an automation membership as the system account, with its expiry" do
    until_then = 30.days.from_now.utc.change(usec: 0)
    deliver(event(expires_at: until_then.iso8601))

    assert_response :success
    membership = CreatorGroupMembership.sole

    assert_equal([@fan, User.system, "automation", until_then], [membership.user, membership.added_by, membership.source, membership.expires_at])
  end

  should "answer a replayed event as a duplicate and do nothing" do
    payload = event
    deliver(payload)
    logged = ModAction.count
    CreatorGroupMembership.where(creator_group: @tier).delete_all
    deliver(payload)

    assert_response :success
    assert_equal({ "duplicate" => true }, response.parsed_body)
    assert_equal(logged, ModAction.count)
    assert_equal(0, CreatorGroupMembership.count)
  end

  should "refuse an unknown group, an unknown user and a past expiry, with a remedy, and let the corrected retry through" do
    payload = event(expires_at: 1.day.ago.utc.iso8601)
    [event(group: "41chan_maple_nonesuch"), event(user_id: 0), payload].each do |sent|
      deliver(sent)

      assert_response(422, sent.inspect)
      assert(response.parsed_body["error"].present?)
    end
    deliver(payload.merge(expires_at: nil))

    assert_response :success
    assert_equal(1, CreatorGroupMembership.count)
  end

  should "refuse to remove a member the creator added, who stays" do
    @tier.add_member!(@fan, by: @maple)
    deliver(event(action: "remove"))

    assert_response 422
    assert_match(/by the creator, not by automation/, response.parsed_body["error"])
    assert_equal("creator", CreatorGroupMembership.sole.source)
  end

  should "stay closed to a caller without a booru session" do
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    body = event.to_json
    post receive_webhooks_path(source: "creator_membership"), params: body, headers: { "Content-Type" => "application/json", CreatorMembershipWebhook::HEADER => signature(body) }

    assert_response 404
    assert_equal(0, CreatorGroupMembership.count)
  end

  # A group's name is unique, but which creator it belongs to is decided by
  # the signed body naming the creator too: a name never reaches across.
  should "refuse a group of another creator, or a creator it does not name, in the same words as a missing group" do
    other = CreatorGallery.create!(slug: "sab", matrix_id: "@sab:41chan.net", user: create(:user))
    CreatorGroup.make!(other, name: "41chan_sab_tier_1", tier: 1, by: other.user)
    answers = [event(group: "41chan_sab_tier_1"), event(creator: "@nobody:41chan.net"), event(group: "41chan_maple_nonesuch"), event(creator: nil)].map do |sent|
      deliver(sent)

      assert_response(422, sent.inspect)
      response.parsed_body["error"].gsub(/"[^"]*"/, "X")
    end

    assert_equal(1, answers.uniq.size, answers.inspect)
    assert_equal(0, CreatorGroupMembership.count)
  end

  # A failure must never look like success to the provider's retry
  # (failure-path-looks-like-success): the event is forgotten on every
  # outcome but a 200, a raised one included.
  should "forget an event that raised, so its retry is applied rather than called a duplicate" do
    payload = event
    CreatorGroup.any_instance.stubs(:add_member!).raises(ActiveRecord::RecordNotUnique, "duplicate key")
    deliver(payload)

    assert_response 409
    assert_match(/retry/, response.parsed_body["error"])

    CreatorGroup.any_instance.stubs(:add_member!).raises(RuntimeError, "the database went away")
    deliver(payload)

    assert_response 500

    CreatorGroup.any_instance.unstub(:add_member!)
    deliver(payload)

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
    assert_equal(1, CreatorGroupMembership.count)
  end
end
