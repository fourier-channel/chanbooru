# frozen_string_literal: true

# THE SIGNED PATH FOR A SIGN-UP PROVIDER -- built, and unused (design
# CREATOR_VISIBILITY Q5, ruled 2026-10-07: "The signed endpoint for a payment
# provider is built alongside, unused"; section 5: automation drives the SAME
# membership methods the panel uses, never a second path).
#
# POST /webhooks/receive?source=creator_membership (an existing route; no
# new routes, 2026-09-24), a JSON body
#
#   { "event_id": "...", "action": "add" | "remove",
#     "creator": "@saber:41chan.net", "group": "41chan_saber_tier_1",
#     "user_id": 123, "expires_at": "2026-12-31T23:59:59Z" | null }
#
# The group is looked up THROUGH the creator the body names (repair,
# 2026-10-09): a group name alone could be read as another creator's, since
# Matrix localparts hold underscores. A group not of that creator answers
# exactly as a missing one does.
#
# signed in the header X-Creator-Membership-Signature: t=<unix seconds>,
# v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>. A signature older or newer
# than WINDOW is refused before it is compared; an event_id seen within
# REPLAY_TTL is answered as a duplicate and does nothing. An event that did
# not succeed -- refused, or raised -- is forgotten, so the provider's retry
# is applied rather than answered as a duplicate (a failure must never look
# like success).
#
# The writes are CreatorGroup#add_member! / #remove_member! as the system
# account with source automation -- so their guards hold here too: a member
# the creator added by hand, or let in by request, is never replaced or
# removed by this path.
#
# UNUSED, AND CLOSED: the secret defaults to blank (503 until it is set), and
# the action is not on MembersOnly::ANONYMOUS_DOORS, so a caller without a
# booru session gets the members-only 404 until the operator opens that door
# for a real provider. Before go-live it wants scoping: one site-wide secret
# lets its holder manage every creator's groups.
module CreatorMembershipWebhook
  class VerificationError < StandardError; end

  HEADER = "X-Creator-Membership-Signature"
  WINDOW = 300
  REPLAY_TTL = 10.minutes

  module_function

  # @return [Array(Integer, Hash)] the status and the JSON answer
  def receive(request)
    secret = Danbooru.config.creator_membership_webhook_secret
    return [503, { error: "creator membership automation is not configured: set creator_membership_webhook_secret" }] if secret.blank?

    body = request.raw_post.to_s
    verify!(request.headers[HEADER].to_s, body, secret)
    data = JSON.parse(body)
    return [422, { error: "the body must be a JSON object with event_id, action, creator, group and user_id" }] unless data.is_a?(Hash) && data["event_id"].present?
    key = "creator-membership-event/#{data["event_id"]}"
    return [200, { duplicate: true }] unless Rails.cache.write(key, true, expires_in: REPLAY_TTL, unless_exist: true)

    # Forgotten on every outcome but success, a raised one included.
    begin
      status, answer = apply(data)
    rescue StandardError
      Rails.cache.delete(key)
      raise
    end
    Rails.cache.delete(key) unless status == 200
    [status, answer]
  rescue JSON::ParserError
    [422, { error: "the body is not JSON: send a JSON object with event_id, action, creator, group and user_id" }]
  end

  # Raises VerificationError unless `header` signs `body` with `secret`
  # within WINDOW seconds of now.
  def verify!(header, body, secret)
    parts = header.split(",").to_h { |part| part.strip.split("=", 2) }
    timestamp = Integer(parts["t"].to_s, exception: false)
    raise VerificationError, "missing or malformed #{HEADER}: send t=<unix seconds>,v1=<hex HMAC-SHA256>" if timestamp.nil? || parts["v1"].blank?
    raise VerificationError, "the signature's timestamp is more than #{WINDOW} seconds from now: sign each request when it is sent" if (Time.now.to_i - timestamp).abs > WINDOW

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
    raise VerificationError, "the signature does not match the body: sign \"<t>.<raw body>\" with the shared secret" unless ActiveSupport::SecurityUtils.secure_compare(expected, parts["v1"])
  end

  def apply(data)
    gallery = CreatorGallery.find_by(matrix_id: data["creator"].to_s)
    group = gallery&.creator_groups&.find_by(name: data["group"].to_s)
    if group.nil?
      return [422, { error: "creator #{data["creator"].to_s.inspect} has no group called #{data["group"].to_s.inspect}: send the creator's Matrix ID " \
                            "and the group's full name, e.g. @saber:41chan.net and 41chan_saber_tier_1" }]
    end

    user = User.find_by(id: data["user_id"])
    return [422, { error: "no booru account has id #{data["user_id"].inspect}: send the booru user id, not a name" }] if user.nil?

    case data["action"]
    when "add"
      expires_at = data["expires_at"].presence && Time.zone.iso8601(data["expires_at"].to_s)
      group.add_member!(user, by: User.system, source: CreatorGroupMembership::AUTOMATION, expires_at: expires_at)
    when "remove"
      group.remove_member!(user, by: User.system, source: CreatorGroupMembership::AUTOMATION)
    else
      return [422, { error: "action must be add or remove, not #{data["action"].inspect}" }]
    end
    [200, { ok: true }]
  rescue ArgumentError
    [422, { error: "expires_at must be an ISO 8601 time, e.g. 2026-12-31T23:59:59Z, or null for no end" }]
  rescue ActiveRecord::RecordInvalid => e
    [422, { error: e.record.errors.full_messages.join(" ") }]
  rescue User::PrivilegeError => e
    [422, { error: e.message }]
  rescue ActiveRecord::RecordNotUnique
    [409, { error: "another change to this membership landed at the same moment; retry this event" }]
  end
end
