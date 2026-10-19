# frozen_string_literal: true

# A booru password set by the server's administrator and shown ONCE, on the
# site, to the person it is for (operator rulings 2026-10-19). Neither the
# booru nor MAS can send mail, so upstream's emailed reset link never arrives,
# and upstream took away the owner's own way to set another account's password
# (5087c3182). The administrator runs bin/chanbooru-reset-password; this class
# generates the password, seals it in the booru's Redis under a random token,
# sets it, and ends the account's login sessions. The person opens
# /password_reset/edit?reveal=<token> and presses the button
# (PasswordResetsController), which reads it back exactly once. The
# administrator never sees the password: nothing here returns it but #reveal.
#
# THE ORDER is generate -> store -> set, with the store undone if the set
# fails, so there is never a sealed password that was not set, nor a set
# password with no sealed copy to show. A sealed password the account no
# longer has -- a later reset replaced it, or it was changed another way -- is
# never shown either: #peek and #reveal check it still signs in.
#
# THE STORED VALUE is "password_reveal:<sha256 hex of the token>" -> the
# payload {user_id, secrets: [{label, password}], created_at} as JSON,
# encrypted with a key derived from secret_key_base AND the token, set NX with
# an expiry of Danbooru.config.password_reveal_ttl. Redis holds neither the
# token nor anything readable, and a copy of Redis and secret_key_base
# together opens nothing without the link. `secrets` is a list so a second
# labelled secret (the Matrix password, when MAS resets are added) is one
# more entry, not a new format.
#
# THE STORE is the booru's Redis, a fresh client per instance and never one
# memoized on the class: a client built under a test's stubbed URL must not
# outlive the test (SavedSearch.redis, 2026-10-19). Tests hand in MockRedis.
class PasswordReveal
  class Error < StandardError; end

  # Redis is not configured or does not answer. Fail loudly: there is no
  # other place to keep the password, and a reset that cannot be shown is a
  # locked account.
  class Unavailable < Error; end

  # What a reset hands the administrator: the link's token, when it stops
  # working, and how many login sessions it ended. Never the password.
  Issued = Data.define(:token, :expires_at, :sessions_ended)

  # Letters and digits with the look-alikes taken out (0 O o, 1 l I), so the
  # password reads off a screen and types into another without a guess.
  ALPHABET = ("a".."z").to_a + ("A".."Z").to_a + ("2".."9").to_a - %w[o O l I]
  # 20 of 56 characters: about 116 bits.
  PASSWORD_LENGTH = 20
  # SecureRandom.urlsafe_base64(32) is 43 characters of this; nothing else is
  # ever looked up.
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{43}\z/

  attr_reader :store

  # @param store [#set, #get, #getdel, #del] where sealed passwords are kept;
  #   the booru's Redis unless a test hands in another.
  def initialize(store: nil)
    @store = store || self.class.redis
  end

  # A new client for the booru's Redis, per call.
  def self.redis
    url = Danbooru.config.redis_url
    raise Unavailable, "PasswordReveal keeps the password in the booru's Redis, and Danbooru.config.redis_url is blank. Fix: set DANBOORU_REDIS_URL (docker-compose.yaml sets redis://redis:6379) and restart the danbooru container." if url.blank?

    ::Redis.new(url: url)
  end

  # Set a new random password on the account, seal it for one showing, and
  # end the account's login sessions.
  #
  # @param user [User] the account to reset.
  # @return [Issued]
  # @raise [Error] for a deleted account, a ttl that is not seconds, or a
  #   token already in use.
  # @raise [Unavailable] if Redis does not answer or refuses; nothing was
  #   changed.
  def reset!(user)
    raise Error, "#{user.name} (##{user.id}) is a deleted account, which cannot sign in, so its password was not reset. Fix: undelete the account first, then run this again." if user.is_deleted?

    ttl = Integer(Danbooru.config.password_reveal_ttl.to_s, 10, exception: false)
    raise Error, "Danbooru.config.password_reveal_ttl is #{Danbooru.config.password_reveal_ttl.to_s.inspect}, not a whole number of seconds above zero, so nothing was changed. Fix: set DANBOORU_PASSWORD_REVEAL_TTL to seconds (86400 is a day), or unset it for the default." unless ttl&.positive?

    password = Array.new(PASSWORD_LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    token = SecureRandom.urlsafe_base64(32)
    key = key_for(token)
    payload = { user_id: user.id, secrets: [{ label: "booru", password: password }], created_at: Time.now.utc.iso8601 }

    stored = command { store.set(key, encryptor(token).encrypt_and_sign(payload.to_json), nx: true, ex: ttl) }
    raise Error, "A one-time link with this token already exists, so nothing was changed. Fix: run this again; a new token is drawn each time." unless stored

    set = false
    begin
      sessions_ended = user.with_lock do
        user.update!(password: password, password_confirmation: password)
        # The way UserDeletion ends them; SessionLoader refuses any login that
        # is not active, so one already logged out is cut off as it stands.
        sessions = user.login_sessions.active.to_a.each(&:revoke!)
        ModAction.log("reset user ##{user.id}'s password from the server's command line", :user_password_reset, subject: user, user: User.system)
        sessions.size
      end
      set = true
    ensure
      # Any failure after the store, an interrupt included, takes the sealed
      # copy back out: a password that was not set is never shown.
      command { store.del(key) } unless set
    end

    Issued.new(token: token, expires_at: Time.now.utc + ttl, sessions_ended: sessions_ended)
  end

  # The sealed payload, read and deleted in one step (Redis GETDEL, 6.2 and
  # up; both compose files pin 6.2.6), so a second ask finds nothing.
  #
  # @param token [String] the token from the link.
  # @return [Hash, nil] {"user_id", "secrets" => [{"label", "password"}],
  #   "created_at"}, or nil when missing, expired, already shown, unreadable,
  #   or holding a password the account no longer has.
  def reveal(token)
    return nil unless token.to_s.match?(TOKEN_FORMAT)

    payload = unseal(command { store.getdel(key_for(token)) }, token)
    payload if account_for(payload)
  end

  # The account a token is for, without using it up: the page the link opens
  # names it and offers the button. Never returns a secret.
  #
  # @param token [String] the token from the link.
  # @return [User, nil] nil when missing, expired, already shown, unreadable,
  #   or holding a password the account no longer has.
  def peek(token)
    return nil unless token.to_s.match?(TOKEN_FORMAT)

    account_for(unseal(command { store.get(key_for(token)) }, token))
  end

  private

  def key_for(token)
    "password_reveal:#{Digest::SHA256.hexdigest(token)}"
  end

  # The account, if the sealed booru password still signs in to it. A second
  # reset leaves the first link holding a password that no longer works, and
  # so does a change of password made any other way: that link reads as used.
  def account_for(payload)
    password = payload && payload["secrets"].find { |secret| secret["label"] == "booru" }&.dig("password")
    return nil if password.blank?

    User.find_by(id: payload["user_id"])&.authenticate_password(password) || nil
  end

  def unseal(sealed, token)
    return nil if sealed.nil?

    json = encryptor(token).decrypt_and_verify(sealed)
    json && JSON.parse(json)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    nil
  end

  # The site's key for this purpose, hashed with the token. Only the token's
  # sha256 is stored (it names the Redis key), so whoever holds a copy of
  # Redis and secret_key_base still opens nothing without the link, and a
  # sealed value moved under another token's key does not open.
  def encryptor(token)
    site_key = Rails.application.key_generator.generate_key("password_reveal", ActiveSupport::MessageEncryptor.key_len)
    ActiveSupport::MessageEncryptor.new(OpenSSL::HMAC.digest("SHA256", site_key, token))
  end

  def command
    yield
  rescue ::Redis::BaseConnectionError => e
    raise Unavailable, "PasswordReveal could not reach the booru's Redis (#{e.class}: #{e.message}). Fix: start it (docker compose up -d redis) and run this again. A reset stopped here gave out no link, and no password is ever set without one."
  rescue ::Redis::CommandError => e
    raise Unavailable, "The booru's Redis refused the command (#{e.message}). Fix: read why in docker compose logs redis -- MISCONF is a disk too full to save to, LOADING a restart still loading, OOM memory -- then run this again. A reset stopped here gave out no link, and no password is ever set without one."
  end
end
