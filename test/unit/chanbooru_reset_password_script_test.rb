# frozen_string_literal: true

require "test_helper"

# script/chanbooru_reset_password.rb, what bin/chanbooru-reset-password runs
# inside the danbooru container (operator rulings 2026-10-19): it resets one
# account's booru password and prints the one-time link that shows it -- the
# account, the link, when it expires, what to do with it -- and NEVER the
# password, which the administrator running it is not to see.
class ChanbooruResetPasswordScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/chanbooru_reset_password.rb").to_s
  LINK = %r{https://booru\.example\.com/password_reset/edit\?reveal=([A-Za-z0-9_-]{43})}

  def run_script(*argv)
    status = nil
    saved = ARGV.dup
    ARGV.replace(argv)
    out, err = capture_io do
      load SCRIPT
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
  end

  setup do
    @store = MockRedis.new
    PasswordReveal.stubs(:redis).returns(@store)
    Danbooru.config.stubs(:canonical_url).returns("https://booru.example.com")
    @user = create(:user, name: "lockedout", password: "old_password")
  end

  should "print the account, the one-time link, its expiry and what to do -- never the password" do
    status, out, err = run_script("--", "lockedout")

    assert_nil(status, err)
    assert_includes(out, "lockedout (##{@user.id})")
    token = out[LINK, 1]
    assert_not_nil(token, out)
    assert_match(/expires: +\d{4}-\d\d-\d\d \d\d:\d\d UTC/, out)
    assert_match(/privately/, out)

    password = PasswordReveal.new.reveal(token)["secrets"].sole["password"]
    assert(@user.reload.authenticate_password(password))
    assert_not_includes(out + err, password)
  end

  should "accept the name without the separator rails runner is given" do
    status, out, = run_script("lockedout")

    assert_nil(status)
    assert_match(LINK, out)
  end

  should "stop on a misspelled name with a sentence naming the fix, changing nothing" do
    status, out, err = run_script("--", "lockedot")

    assert_equal(1, status)
    assert_match(/no booru account is named "lockedot"/, err)
    assert_match(/^fix: /, err)
    assert_no_match(LINK, out)
    assert_empty(@store.keys("*"))
    assert(@user.reload.authenticate_password("old_password"))
  end

  should "ask for exactly one name" do
    status, _out, err = run_script("--")
    assert_equal(2, status)
    assert_match(/^fix: /, err)

    status, = run_script("--", "lockedout", "someone_else")
    assert_equal(2, status)
    assert_empty(@store.keys("*"))
  end

  should "stop on a deleted account, saying why" do
    @user.update!(is_deleted: true)

    status, _out, err = run_script("--", "lockedout")

    assert_equal(1, status)
    assert_match(/deleted/, err)
    assert_match(/fix:/i, err)
    assert_empty(@store.keys("*"))
  end

  should "stop with the reasons and a fix when the account cannot be saved, changing nothing" do
    @user.update_columns(per_page: 0) # rubocop:disable Rails/SkipsModelValidations -- an account no save would accept, as an old one can be

    status, out, err = run_script("--", "lockedout")

    assert_equal(1, status)
    assert_match(/^FAIL: .*Per page/, err)
    assert_match(/^fix: /, err)
    assert_no_match(LINK, out)
    assert_empty(@store.keys("*"))
    assert(@user.reload.authenticate_password("old_password"))
  end

  should "stop with a sentence and a fix on any other error, not a backtrace" do
    PasswordReveal.any_instance.stubs(:reset!).raises(RuntimeError, "something unforeseen")

    status, out, err = run_script("--", "lockedout")

    assert_equal(1, status)
    assert_match(/^FAIL: RuntimeError: something unforeseen$/, err)
    assert_match(/^fix: /, err)
    assert_no_match(LINK, out)
  end

  should "stop with the fix when Redis cannot be reached" do
    PasswordReveal.stubs(:redis).returns(Redis.new(url: "redis://127.0.0.1:1", reconnect_attempts: 0, connect_timeout: 1))

    status, out, err = run_script("--", "lockedout")

    assert_equal(1, status)
    assert_match(/Redis/, err)
    assert_match(/fix:/i, err)
    assert_no_match(LINK, out)
    assert(@user.reload.authenticate_password("old_password"))
  end
end
