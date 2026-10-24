# frozen_string_literal: true

require "test_helper"

# PasswordReveal (operator rulings 2026-10-19): the server's administrator
# resets a person's booru password from the command line. The password is
# generated, set, and sealed in Redis for ONE showing on the site; the
# administrator never sees it. Redis is stood in for by MockRedis, except
# where the test is about Redis being unreachable.
class PasswordRevealTest < ActiveSupport::TestCase
  def key_for(token) = "password_reveal:#{Digest::SHA256.hexdigest(token)}"

  def password_of(issued) = @reveal.reveal(issued.token)["secrets"].sole["password"]

  setup do
    @store = MockRedis.new
    @reveal = PasswordReveal.new(store: @store)
    @user = create(:user, name: "lockedout", password: "old_password")
  end

  context "reset!" do
    should "set a generated password, which the one showing returns" do
      issued = @reveal.reset!(@user)
      payload = @reveal.reveal(issued.token)

      assert_equal(@user.id, payload["user_id"])
      assert_equal("booru", payload["secrets"].sole["label"])
      assert(@user.reload.authenticate_password(payload["secrets"].sole["password"]))
      assert_not(@user.authenticate_password("old_password"))
      assert_match(/\A\d{4}-\d\d-\d\dT/, payload["created_at"])
    end

    should "generate a strong password from an alphabet with no look-alike characters" do
      passwords = Array.new(5) { password_of(@reveal.reset!(@user)) }

      passwords.each do |password|
        assert_operator(password.length, :>=, 16)
        assert_match(/\A[a-zA-Z2-9]+\z/, password)
        assert_no_match(/[0O1lIo]/, password)
      end
      assert_equal(5, passwords.uniq.size)
    end

    should "store under the sha256 of the token, for as long as the config says" do
      freeze_time
      Danbooru.config.stubs(:password_reveal_ttl).returns(5.minutes)
      issued = @reveal.reset!(@user)

      assert_equal([key_for(issued.token)], @store.keys("*"))
      assert_equal(300, @store.ttl(key_for(issued.token)))
      assert_equal(5.minutes.from_now, issued.expires_at)
      assert_match(/\A[A-Za-z0-9_-]{43}\z/, issued.token)
    end

    should "take a ttl given as a string, as an environment override arrives" do
      freeze_time
      Danbooru.config.stubs(:password_reveal_ttl).returns("600")
      issued = @reveal.reset!(@user)

      assert_equal(600, @store.ttl(key_for(issued.token)))
    end

    should "default to 24 hours" do
      assert_equal(24.hours, Danbooru::Configuration.new.password_reveal_ttl)
    end

    should "seal the stored value under a key only the token opens, not secret_key_base alone" do
      issued = @reveal.reset!(@user)
      raw = @store.get(key_for(issued.token))
      site_key = Rails.application.key_generator.generate_key("password_reveal", ActiveSupport::MessageEncryptor.key_len)
      opened = [{ purpose: key_for(issued.token) }, {}].map do |options|
        ActiveSupport::MessageEncryptor.new(site_key).decrypt_and_verify(raw, **options)
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        nil
      end

      assert_equal([nil, nil], opened)
      assert_not_nil(@reveal.reveal(issued.token))
    end

    should "refuse a ttl that is not a whole number of seconds, naming the setting, and change nothing" do
      ["24h", "0", "-5"].each do |ttl|
        Danbooru.config.stubs(:password_reveal_ttl).returns(ttl)

        error = assert_raises(PasswordReveal::Error) { @reveal.reset!(@user) }
        assert_match(/DANBOORU_PASSWORD_REVEAL_TTL/, error.message)
        assert_match(/Fix:/, error.message)
      end
      assert_empty(@store.keys("*"))
      assert(@user.reload.authenticate_password("old_password"))
    end

    should "seal the stored value: no password, account name or field names readable in it" do
      issued = @reveal.reset!(@user)
      raw = @store.get(key_for(issued.token))
      password = password_of(issued)

      assert_not_includes(raw, password)
      assert_not_includes(raw, @user.name)
      assert_not_includes(raw, "user_id")
      assert_not_includes(raw, "secrets")
    end

    should "remove the sealed copy and keep the old password when setting the password fails" do
      @user.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@user))

      assert_raises(ActiveRecord::RecordInvalid) { @reveal.reset!(@user) }
      assert_empty(@store.keys("*"))
      assert(@user.reload.authenticate_password("old_password"))
    end

    should "roll the password back and remove the sealed copy when the audit row cannot be written" do
      ModAction.stubs(:log).raises(ActiveRecord::RecordNotFound)

      assert_raises(ActiveRecord::RecordNotFound) { @reveal.reset!(@user) }
      assert_empty(@store.keys("*"))
      assert(@user.reload.authenticate_password("old_password"))
    end

    should "not set a password whose sealed copy could not be stored" do
      token = SecureRandom.urlsafe_base64(32)
      SecureRandom.stubs(:urlsafe_base64).returns(token)
      first = password_of(@reveal.reset!(@user))
      @store.set(key_for(token), "taken")

      assert_raises(PasswordReveal::Error) { @reveal.reset!(@user) }
      assert(@user.reload.authenticate_password(first))
      assert_equal("taken", @store.get(key_for(token)))
    end

    should "refuse a deleted account, changing nothing" do
      @user.update!(is_deleted: true)

      error = assert_raises(PasswordReveal::Error) { @reveal.reset!(@user) }
      assert_match(/deleted/, error.message)
      assert_empty(@store.keys("*"))
    end

    # A login already logged out keeps saying so: SessionLoader refuses every
    # login that is not active, so a copy of its cookie is cut off already
    # (password_reveal_pages_test replays one).
    should "end the account's active login sessions, and nobody else's" do
      mine = create(:login_session, user: @user)
      ended = create(:login_session, user: @user, status: :logged_out)
      theirs = create(:login_session)

      issued = @reveal.reset!(@user)

      assert_equal("revoked", mine.reload.status)
      assert_equal("logged_out", ended.reload.status)
      assert_equal("active", theirs.reload.status)
      assert_equal(1, issued.sessions_ended)
    end

    should "log the reset as the server's, without the password, for moderators" do
      issued = @reveal.reset!(@user)
      password = password_of(issued)
      action = ModAction.user_password_reset.sole

      assert_equal(@user, action.subject)
      assert_equal(User.system, action.creator)
      assert_match(/command line/, action.description)
      assert_not_includes(action.description, password)
      assert_includes(ModAction.visible(create(:moderator_user)), action)
      assert_not_includes(ModAction.visible(create(:user)), action)
    end
  end

  context "reveal" do
    should "answer once, then nil" do
      issued = @reveal.reset!(@user)

      assert_not_nil(@reveal.reveal(issued.token))
      assert_nil(@reveal.reveal(issued.token))
      assert_empty(@store.keys("*"))
    end

    should "answer nil once the time is up" do
      issued = @reveal.reset!(@user)

      travel(Danbooru.config.password_reveal_ttl + 1.second) { assert_nil(@reveal.reveal(issued.token)) }
    end

    should "answer nil for a link a later reset replaced, whose password no longer signs in" do
      first = @reveal.reset!(@user)
      second = @reveal.reset!(@user)

      assert_nil(@reveal.reveal(first.token))
      assert(@user.reload.authenticate_password(password_of(second)))
    end

    should "answer nil once the account's password was changed some other way" do
      issued = @reveal.reset!(@user)
      @user.update!(password: "changed_since", password_confirmation: "changed_since")

      assert_nil(@reveal.reveal(issued.token))
    end

    should "answer nil for a token never issued, or not shaped like one" do
      assert_nil(@reveal.reveal(SecureRandom.urlsafe_base64(32)))
      assert_nil(@reveal.reveal(""))
      assert_nil(@reveal.reveal("../../password_reveal:*"))
    end

    should "answer nil for a value it cannot open" do
      issued = @reveal.reset!(@user)
      @store.set(key_for(issued.token), "garbage")

      assert_nil(@reveal.reveal(issued.token))
    end

    should "not open a sealed value moved under another token's key" do
      mine = @reveal.reset!(@user)
      theirs = @reveal.reset!(create(:user))
      @store.set(key_for(mine.token), @store.get(key_for(theirs.token)))

      assert_nil(@reveal.reveal(mine.token))
    end
  end

  context "peek" do
    should "name the account and leave the secret in place" do
      issued = @reveal.reset!(@user)

      assert_equal(@user, @reveal.peek(issued.token))
      assert_equal(@user, @reveal.peek(issued.token))
      assert_not_nil(@reveal.reveal(issued.token))
      assert_nil(@reveal.peek(issued.token))
    end

    should "answer nil for a token never issued, or a value it cannot open" do
      issued = @reveal.reset!(@user)
      @store.set(key_for(issued.token), "garbage")

      assert_nil(@reveal.peek(SecureRandom.urlsafe_base64(32)))
      assert_nil(@reveal.peek(issued.token))
    end

    should "answer nil for a link a later reset replaced" do
      first = @reveal.reset!(@user)
      second = @reveal.reset!(@user)

      assert_nil(@reveal.peek(first.token))
      assert_equal(@user, @reveal.peek(second.token))
    end
  end

  # bin/chanbooru-reset-password --matrix: the Matrix password rides in the
  # same link. It is made and set in MAS by the host; here it is only sealed.
  context "a second secret" do
    setup do
      @matrix = { label: "matrix", account: "@lockedout:41chan.net", password: "Matrix2345abcdefghij" }
    end

    should "be sealed beside the booru password and shown with it, with its account" do
      issued = @reveal.reset!(@user, also: [@matrix])
      secrets = @reveal.reveal(issued.token)["secrets"]

      assert_equal(%w[booru matrix], secrets.pluck("label"))
      assert_equal({ "label" => "matrix", "account" => "@lockedout:41chan.net", "password" => "Matrix2345abcdefghij" }, secrets.last)
      assert(@user.reload.authenticate_password(secrets.first["password"]))
      assert_not_includes(@store.get(key_for(issued.token)).to_s, "Matrix2345abcdefghij")
    end

    should "refuse a password not made from the reset's own alphabet and length, changing nothing" do
      ["Matrix2345abcdefgh", "Matrix2345abcdefghi0", "Matrix2345abcdefghijk", "", nil].each do |password|
        error = assert_raises(PasswordReveal::Error) { @reveal.reset!(@user, also: [@matrix.merge(password: password)]) }
        assert_match(/Fix:/, error.message)
        assert_not_includes(error.message, "Matrix2345")
      end
      assert_empty(@store.keys("*"))
      assert(@user.reload.authenticate_password("old_password"))
    end

    should "refuse a label that is booru, blank or repeated, changing nothing" do
      [[@matrix.merge(label: "booru")], [@matrix.merge(label: "")], [@matrix, @matrix]].each do |also|
        error = assert_raises(PasswordReveal::Error) { @reveal.reset!(@user, also: also) }
        assert_match(/label/, error.message)
      end
      assert_empty(@store.keys("*"))
      assert(@user.reload.authenticate_password("old_password"))
    end
  end

  context "drop!" do
    setup do
      @matrix = { label: "matrix", account: "@lockedout:41chan.net", password: "Matrix2345abcdefghij" }
    end

    should "take the secret out and leave the booru password, the link and its expiry as they were" do
      freeze_time
      issued = @reveal.reset!(@user, also: [@matrix])
      travel(1.hour)

      assert(@reveal.drop!(issued.token, "matrix"))
      assert_equal(Danbooru.config.password_reveal_ttl.to_i - 1.hour.to_i, @store.ttl(key_for(issued.token)))
      assert_equal(@user, @reveal.peek(issued.token))
      assert(@user.reload.authenticate_password(password_of(issued)))
    end

    should "answer false for a link without that secret, already shown, or never issued, creating nothing" do
      plain = @reveal.reset!(@user)
      assert_not(@reveal.drop!(plain.token, "matrix"))

      shown = @reveal.reset!(@user, also: [@matrix])
      @reveal.reveal(shown.token)
      assert_not(@reveal.drop!(shown.token, "matrix"))
      assert_not(@reveal.drop!(SecureRandom.urlsafe_base64(32), "matrix"))
      assert_not(@reveal.drop!("not a token", "matrix"))
      assert_equal([key_for(plain.token)], @store.keys("*"))
    end

    should "not bring back a link shown between its read and its write" do
      issued = @reveal.reset!(@user, also: [@matrix])
      sealed = @store.get(key_for(issued.token))
      @store.del(key_for(issued.token))
      @store.stubs(:get).returns(sealed)

      assert_not(@reveal.drop!(issued.token, "matrix"))
      assert_empty(@store.keys("*"))
    end

    should "never drop the booru password" do
      issued = @reveal.reset!(@user)

      error = assert_raises(PasswordReveal::Error) { @reveal.drop!(issued.token, "booru") }
      assert_match(/Fix:/, error.message)
      assert_not_nil(@reveal.reveal(issued.token))
    end
  end

  context "without Redis" do
    should "raise an error naming its fix when Redis cannot be reached, and change nothing" do
      reveal = PasswordReveal.new(store: Redis.new(url: "redis://127.0.0.1:1", reconnect_attempts: 0, connect_timeout: 1))

      error = assert_raises(PasswordReveal::Unavailable) { reveal.reset!(@user) }
      assert_match(/Redis/, error.message)
      assert_match(/Fix:/, error.message)
      assert(@user.reload.authenticate_password("old_password"))
      assert_raises(PasswordReveal::Unavailable) { reveal.peek(SecureRandom.urlsafe_base64(32)) }
      assert_raises(PasswordReveal::Unavailable) { reveal.reveal(SecureRandom.urlsafe_base64(32)) }
    end

    should "raise an error naming its fix when Redis refuses the command, and change nothing" do
      @store.stubs(:set).raises(Redis::CommandError, "MISCONF Redis is configured to save RDB snapshots, but it's currently unable to persist to disk")

      error = assert_raises(PasswordReveal::Unavailable) { @reveal.reset!(@user) }
      assert_match(/MISCONF/, error.message)
      assert_match(/Fix:/, error.message)
      assert(@user.reload.authenticate_password("old_password"))

      @store.stubs(:get).raises(Redis::CommandError, "LOADING Redis is loading the dataset in memory")
      @store.stubs(:getdel).raises(Redis::CommandError, "LOADING Redis is loading the dataset in memory")
      assert_raises(PasswordReveal::Unavailable) { @reveal.peek(SecureRandom.urlsafe_base64(32)) }
      assert_raises(PasswordReveal::Unavailable) { @reveal.reveal(SecureRandom.urlsafe_base64(32)) }
    end

    should "refuse to start with no redis_url, naming the setting" do
      Danbooru.config.stubs(:redis_url).returns("")

      error = assert_raises(PasswordReveal::Unavailable) { PasswordReveal.new }
      assert_match(/DANBOORU_REDIS_URL/, error.message)
    end

    should "build a fresh client from the config each time, so no test's stub outlives it" do
      Danbooru.config.stubs(:redis_url).returns("redis://127.0.0.1:1")
      first = PasswordReveal.new.store
      Danbooru.config.stubs(:redis_url).returns("redis://127.0.0.1:2")

      assert_not_same(first, PasswordReveal.new.store)
      assert_equal(2, PasswordReveal.new.store.connection[:port])
    end
  end
end
