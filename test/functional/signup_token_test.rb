# frozen_string_literal: true

require "test_helper"

# Registration tokens are what holds 41chan shut once signups are no longer
# closed outright, so every way of NOT having a good one has to be a refusal.
#
# These live here rather than in upstream's users_controller_test because
# enable_signup? is TRUE under test -- thirty-nine of upstream's own tests POST
# to /users and expect an account. UserPolicy#create? returns early on that, so
# the token path is never reached there. Here it is stubbed off, which is the
# only place the gate is exercised.
#
# The shape of this file is deliberate: one passing case, and eight ways to
# fail. A gate is only worth having if it can say no.
class SignupTokenTest < ActionDispatch::IntegrationTest
  # A successful signup logs the new account in, and UserPolicy#create? requires
  # an ANONYMOUS visitor -- correctly, since a logged-in user has no business
  # making a second account. So a test that signs up twice has to arrive as a
  # stranger the second time. `reset!` drops the session, which is what closing
  # the browser would do.
  def signup(token, name: "newcomer#{rand(1_000_000)}", fresh: true)
    reset! if fresh
    post users_path, params: {
      user: {
        name: name,
        password: "hunter22longenough",
        password_confirmation: "hunter22longenough",
        signup_token: token,
      },
    }
  end

  context "With signups gated on a token" do
    setup do
      Danbooru.config.stubs(:enable_signup?).returns(false)
      Danbooru.config.stubs(:signup_requires_token?).returns(true)
      @admin = create(:admin_user)
      @token = SignupToken.create!(token: "GOODCODE1234", creator: @admin, note: "test")
    end

    should "create an account for a valid token and spend one use" do
      assert_difference("User.count", 1) do
        signup("GOODCODE1234")
      end
      assert_equal(1, @token.reload.times_used)
    end

    should "refuse with NO token at all" do
      assert_no_difference("User.count") { signup(nil) }
      assert_response 403
    end

    should "refuse with a blank token" do
      assert_no_difference("User.count") { signup("") }
      assert_response 403
    end

    should "refuse with an unknown token" do
      assert_no_difference("User.count") { signup("NOTATOKEN123") }
      assert_response 403
    end

    should "refuse a REVOKED token" do
      @token.update!(revoked_at: Time.current)
      assert_no_difference("User.count") { signup("GOODCODE1234") }
      assert_response 403
    end

    should "refuse an EXPIRED token" do
      @token.update!(expires_at: 1.hour.ago)
      assert_no_difference("User.count") { signup("GOODCODE1234") }
      assert_response 403
    end

    should "refuse a token that has run out of uses" do
      @token.update!(usage_limit: 1, times_used: 1)
      assert_no_difference("User.count") { signup("GOODCODE1234") }
      assert_response 403
    end

    should "let an unlimited token be used more than once" do
      # usage_limit nil is MAS's --unlimited, and is how the operator's live
      # Matrix token is configured.
      assert_difference("User.count", 2) do
        signup("GOODCODE1234", name: "firstcomer")
        signup("GOODCODE1234", name: "secondcomer")
      end
      assert_equal(2, @token.reload.times_used)
    end

    should "honour a usage limit exactly" do
      @token.update!(usage_limit: 2)
      assert_difference("User.count", 2) do
        signup("GOODCODE1234", name: "onlyone")
        signup("GOODCODE1234", name: "onlytwo")
      end
      assert_no_difference("User.count") { signup("GOODCODE1234", name: "onlythree") }
      assert_equal(2, @token.reload.times_used)
    end

    should "NOT spend a use when the account itself fails to save" do
      # The reason creation and redemption share a transaction. A rejected
      # password must not cost the invitee their invite.
      assert_no_difference("User.count") do
        post users_path, params: {
          user: { name: "badpass", password: "x", password_confirmation: "y", signup_token: "GOODCODE1234" },
        }
      end
      assert_equal(0, @token.reload.times_used)
    end

    should "not be case-insensitive, but should forgive surrounding whitespace" do
      # A pasted code often carries a trailing newline; that is transcription,
      # not a different secret. Case is a different secret.
      assert_difference("User.count", 1) { signup("  GOODCODE1234 \n", name: "pastey") }
      assert_no_difference("User.count") { signup("goodcode1234", name: "lowercase") }
    end
  end

  context "The token model" do
    setup { @admin = create(:admin_user) }

    should "describe its own state" do
      t = SignupToken.create!(token: "STATEFUL1234", creator: @admin)
      assert_equal("usable", t.status)
      t.update!(usage_limit: 1, times_used: 1)
      assert_equal("used up", t.status)
      t.update!(usage_limit: nil, expires_at: 1.minute.ago)
      assert_equal("expired", t.status)
      t.update!(expires_at: nil, revoked_at: Time.current)
      assert_equal("revoked", t.status)
    end

    should "raise rather than return false when redeemed while unusable" do
      # So a caller that ignores the return value cannot let someone through.
      t = SignupToken.create!(token: "REVOKED12345", creator: @admin, revoked_at: Time.current)
      assert_raises(SignupToken::InvalidTokenError) { t.redeem! }
    end

    should "generate a distinct token when none is given" do
      a = SignupToken.create!(creator: @admin)
      b = SignupToken.create!(creator: @admin)
      assert_not_equal(a.token, b.token)
      assert_equal(SignupToken::TOKEN_LENGTH, a.token.length)
    end
  end

  context "The admin panel" do
    setup do
      @admin = create(:admin_user)
      @member = create(:user)
    end

    should "let an admin list, mint and revoke codes" do
      get_auth admin_signup_tokens_path, @admin
      assert_response :success

      assert_difference("SignupToken.count", 1) do
        post_auth admin_signup_tokens_path, @admin,
                  params: { signup_token: { note: "for the regulars", usage_limit: 5 } }
      end
      minted = SignupToken.order(:created_at).last
      assert_equal(5, minted.usage_limit)
      assert_equal(@admin.id, minted.creator_id)
      assert(minted.usable?)

      assert_difference("SignupToken.where.not(revoked_at: nil).count", 1) do
        post_auth revoke_admin_signup_token_path(minted), @admin
      end
    end

    should "refuse a member and an anonymous visitor" do
      # Minting a code is handing out the key to the site.
      get_auth admin_signup_tokens_path, @member
      assert_response 403

      get admin_signup_tokens_path
      assert_response 403
    end

    should "generate a code when the field is left blank" do
      token = SignupToken.create!(creator: @admin, token: SignupToken.generate_token)
      assert_equal(SignupToken::TOKEN_LENGTH, token.token.length)
      assert(token.usable?)
    end

    should "revoke rather than delete, so the history survives" do
      token = SignupToken.create!(creator: @admin, token: "REVOKEME1234", times_used: 3)
      token.revoke!(by: @admin)
      assert(token.revoked?)
      assert_not(token.usable?)
      assert_equal(3, token.reload.times_used, "the history is still there")
      assert(SignupToken.exists?(token.id))
    end
  end
end
