# frozen_string_literal: true

require "test_helper"

# The one-time password page (PasswordReveal, operator rulings 2026-10-19),
# riding the existing reset routes: GET /password_reset/edit?reveal= says
# whose password it is and offers a button, and never uses the link up (link
# previews and prefetchers GET it too); PUT /password_reset with reveal shows
# the password once. The emailed signed_id flow on the same two actions is
# upstream's and is held by password_resets_controller_test.
class PasswordRevealPagesTest < ActionDispatch::IntegrationTest
  GONE = "This link was already used or has expired. Ask an administrator for a new one."

  # The page the link opens sends strict-origin, not no-referrer: its URL
  # carries the token, which strict-origin never puts in a Referer, and under
  # no-referrer a browser sends the button's PUT with `Origin: null`, which
  # Rails refuses whenever its origin check is on. The password's own page
  # carries no token in its URL and sends nothing at all.
  def assert_private_headers(referrer_policy)
    assert_equal("no-store", response.headers["Cache-Control"])
    assert_equal(referrer_policy, response.headers["Referrer-Policy"])
  end

  # The Origin a browser puts on a same-origin form PUT from a page sent with
  # this referrer policy (the Fetch standard, "append a request Origin
  # header"): `null` under no-referrer, the page's own origin under every
  # other policy when nothing is downgraded from https to http.
  def browser_origin_for(referrer_policy)
    (referrer_policy == "no-referrer") ? "null" : request.base_url
  end

  def stored = @store.keys("password_reveal:*")

  setup do
    @store = MockRedis.new
    PasswordReveal.stubs(:redis).returns(@store)
    @user = create(:user, name: "lockedout", password: "old_password")
    @token = PasswordReveal.new.reset!(@user).token
  end

  context "GET /password_reset/edit?reveal=" do
    should "say whose password it is and offer the button, and leave the link working" do
      2.times do
        get edit_password_reset_path(reveal: @token)

        assert_response :success
        assert_includes(css_select("#a-reveal").text.squish, "An administrator set a new password for lockedout. It can be shown once.")
        assert_select "form[action='#{password_reset_path}'][method=post]" do
          assert_select "input[name=_method][value=put]"
          assert_select "input[type=hidden][name=reveal][value='#{@token}']"
          assert_select "[type=submit]"
        end
        assert_private_headers("strict-origin")
      end
      assert_equal(1, stored.size)
    end

    should "say used or expired for a token it does not hold, without saying whether it ever existed" do
      get edit_password_reset_path(reveal: SecureRandom.urlsafe_base64(32))

      assert_response 404
      assert_includes(response.body, GONE)
      assert_private_headers("strict-origin")

      get edit_password_reset_path(reveal: "")
      assert_response 404
      assert_includes(response.body, GONE)
    end

    should "say used or expired for a link a later reset replaced, offering no button" do
      PasswordReveal.new.reset!(@user)

      get edit_password_reset_path(reveal: @token)

      assert_response 404
      assert_includes(response.body, GONE)
      assert_select "#a-reveal form", count: 0
    end
  end

  context "PUT /password_reset with reveal" do
    should "show the password once, then say used or expired" do
      put password_reset_path, params: { reveal: @token }

      assert_response :success
      assert_private_headers("no-referrer")
      password = css_select("#a-revealed pre").text.strip
      assert(@user.reload.authenticate_password(password), "the page must show the password the account now has")
      assert_includes(response.body, "lockedout")
      assert_select "a[href='#{login_path}']", text: "Sign in"
      assert_select "a[href='#{edit_password_path}']"
      assert_empty(stored)

      put password_reset_path, params: { reveal: @token }

      assert_response 404
      assert_private_headers("no-referrer")
      assert_includes(response.body, GONE)
      assert_not_includes(response.body, password)

      post session_path, params: { session: { name: "lockedout", password: password }}
      assert_equal(@user.id, session[:user_id])
    end

    should "show a Matrix password set in the same reset beside the booru one, naming its account and where to change it" do
      token = PasswordReveal.new.reset!(@user, also: [{ label: "matrix", account: "@lockedout:41chan.net", password: "Matrix2345abcdefghij" }]).token

      put password_reset_path, params: { reveal: token }

      assert_response :success
      booru = css_select("#a-revealed .password-reveal-secret[data-label=booru] pre").text.strip
      assert(@user.reload.authenticate_password(booru))
      assert_select "#a-revealed .password-reveal-secret[data-label=matrix]" do
        assert_select "pre", text: "Matrix2345abcdefghij"
        assert_select "strong", text: "@lockedout:41chan.net"
      end
      assert_includes(css_select("#a-revealed").text.squish, "Sign in to Technetium as @lockedout:41chan.net with the Matrix password")
      assert_select "a[href='#{Danbooru.config.fourier_matrix_account_url}']", text: "Matrix account"
    end

    should "say nothing of Matrix when the reset set only the booru password" do
      put password_reset_path, params: { reveal: @token }

      assert_select "#a-revealed .password-reveal-secret", count: 1
      assert_not_includes(response.body, "Technetium")
    end

    should "check the button's CSRF token, refusing without using the link up" do
      ActionController::Base.allow_forgery_protection = true
      get edit_password_reset_path(reveal: @token)
      csrf = css_select("#a-reveal form input[name=authenticity_token]").sole["value"]

      put password_reset_path, params: { reveal: @token }
      assert_response 403
      assert_equal(1, stored.size)

      put password_reset_path, params: { reveal: @token, authenticity_token: csrf }
      assert_response :success
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    should "keep the button working with Rails' origin check on, sent as a browser sends it from the page" do
      origin_check = ActionController::Base.forgery_protection_origin_check
      ActionController::Base.allow_forgery_protection = true
      ActionController::Base.forgery_protection_origin_check = true
      get edit_password_reset_path(reveal: @token)
      csrf = css_select("#a-reveal form input[name=authenticity_token]").sole["value"]
      origin = browser_origin_for(response.headers["Referrer-Policy"])

      put password_reset_path, params: { reveal: @token, authenticity_token: csrf }, headers: { Origin: origin }

      assert_response :success
      assert(@user.reload.authenticate_password(css_select("#a-revealed pre").text.strip))
    ensure
      ActionController::Base.allow_forgery_protection = false
      ActionController::Base.forgery_protection_origin_check = origin_check
    end

    should "refuse an ask that is not for html without using the link up" do
      put password_reset_path(format: :json), params: { reveal: @token }

      assert_response 406
      assert_equal(1, stored.size)
    end

    should "rate-limit the button as the reset form's own update is, without using the link up" do
      Danbooru.config.stubs(:rate_limits_enabled?).returns(true)
      freeze_time

      50.times do
        put password_reset_path, params: { reveal: SecureRandom.urlsafe_base64(32) }, headers: { REMOTE_ADDR: "1.2.3.4" }
        assert_response 404
      end
      put password_reset_path, params: { reveal: @token }, headers: { REMOTE_ADDR: "1.2.3.4" }

      assert_response 429
      assert_equal(1, stored.size)
    end
  end

  context "without Redis" do
    should "answer 503 with a sentence, on the page and the button alike" do
      PasswordReveal.stubs(:redis).raises(PasswordReveal::Unavailable, "Redis is down. Fix: start it")

      get edit_password_reset_path(reveal: @token)
      assert_response 503
      assert_includes(response.body, "Try again in a few minutes.")

      put password_reset_path, params: { reveal: @token }
      assert_response 503
      assert_includes(response.body, "Try again in a few minutes.")
    end

    should "answer 503 with a sentence when Redis refuses the command" do
      @store.stubs(:get).raises(Redis::CommandError, "LOADING Redis is loading the dataset in memory")
      @store.stubs(:getdel).raises(Redis::CommandError, "LOADING Redis is loading the dataset in memory")

      get edit_password_reset_path(reveal: @token)
      assert_response 503
      assert_includes(response.body, "Try again in a few minutes.")

      put password_reset_path, params: { reveal: @token }
      assert_response 503
      assert_includes(response.body, "Try again in a few minutes.")
    end
  end

  context "who may open it" do
    should "open for a signed-out viewer with the anonymous default-deny on" do
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)

      get edit_password_reset_path(reveal: @token)
      assert_response :success

      put password_reset_path, params: { reveal: @token }
      assert_response :success
      assert(@user.reload.authenticate_password(css_select("#a-revealed pre").text.strip))
    end

    should "open for a signed-in viewer too, leaving their session as it was" do
      viewer = create(:user)

      get_auth edit_password_reset_path(reveal: @token), viewer
      assert_response :success

      put password_reset_path, params: { reveal: @token }
      assert_response :success
      assert_equal(viewer.id, session[:user_id])
    end
  end

  context "the reset itself" do
    should "sign the account out where it was signed in" do
      victim = create(:user, password: "password")
      login_as(victim)
      get password_reset_path
      assert_redirected_to profile_path

      PasswordReveal.new.reset!(victim)
      get password_reset_path

      assert_response :success
      assert_nil(session[:user_id])
    end

    # The cookie store keeps the whole session in the cookie, so a copy taken
    # before a logout carries the user id and login id on its own. The login
    # is logged_out, not active, so the reset has nothing to revoke: the copy
    # must be refused for what it is.
    should "cut off a copy of the cookie whose login was logged out before the reset" do
      victim = create(:user, password: "password")
      login_as(victim)
      copied = cookies[Danbooru.config.session_cookie_name]
      delete session_path

      PasswordReveal.new.reset!(victim)
      cookies[Danbooru.config.session_cookie_name] = copied
      get password_reset_path

      assert_response :success
      assert_nil(session[:user_id])
    end
  end

  context "the logs" do
    should "never carry the token" do
      get edit_password_reset_path(reveal: @token)
      assert_equal("[FILTERED]", request.filtered_parameters["reveal"])
      assert_not_includes(request.filtered_path, @token)

      put password_reset_path, params: { reveal: @token }
      assert_equal("[FILTERED]", request.filtered_parameters["reveal"])
    end

    should "never carry the token inside another parameter either, as the login link's ?url= does" do
      get login_path(url: edit_password_reset_path(reveal: @token))

      assert_response :success
      assert_not_includes(request.filtered_path, @token)
      assert_not_includes(request.filtered_parameters.to_s, @token)
    end
  end
end
