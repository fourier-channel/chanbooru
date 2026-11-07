# frozen_string_literal: true

require "test_helper"

# Every Matrix account gets a booru account with the same name, made and
# signed in on the first booru request that carries the verified identity
# (operator, 2026-11-07; MatrixAccount, SessionLoader#load_matrix_account).
# A newcomer opening the booru inside Technetium had no booru session, and
# every picture the gate asked about came back 404.
#
# The switch (Danbooru.config.matrix_accounts_from_identity?) is off under
# test, so upstream's suite keeps measuring upstream's sessions; it is stubbed
# on here, which makes this file the place the behaviour is proven.
class MatrixAccountTest < ActionDispatch::IntegrationTest
  def identity(mxid)
    { "X-Fourier-Identity" => mxid }
  end

  def signed_in_name
    get fourier_identity_path(format: :json)
    response.parsed_body["signed_in"] ? User.find(session[:user_id]).name : nil
  end

  setup do
    Danbooru.config.stubs(:matrix_accounts_from_identity?).returns(true)
    # No name is anyone's Matrix username unless a test says so
    # (MatrixUsernameValidator asks the homeserver about every new name).
    Danbooru.config.stubs(:fourier_media_origin).returns("https://chat.example")
    Danbooru.config.stubs(:fourier_matrix_profile_token).returns("syt_reader")
    Danbooru::Http.any_instance.stubs(:get).returns(stub(code: 404))
  end

  context "a first request with a verified identity" do
    should "make a Restricted account under the Matrix username, linked, and sign it in" do
      assert_difference("User.count", 1) do
        get fourier_identity_path(format: :json), headers: identity("@Alice:41chan.net")
      end

      user = User.find_by_name("alice")
      assert_equal("@alice:41chan.net", user.matrix_id)
      assert_equal(User::Levels::RESTRICTED, user.level)
      assert_equal(false, user.requires_verification)
      assert_equal(user.id, session[:user_id])
      assert_equal(true, response.parsed_body["signed_in"])
      assert_equal(1, UserEvent.where(user: user, category: "user_creation").count)
      assert_equal(0, UserEvent.where(user: user, category: "login").count)
    end

    should "make it once: the next request is the same account, already signed in" do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")

      assert_no_difference(["User.count", "UserEvent.count"]) do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
    end

    should "get past the members-only gate, which is what the pictures needed" do
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      get tags_path
      assert_response 404

      get tags_path, headers: identity("@alice:41chan.net")
      assert_response :success
    end

    should "make nothing without the header" do
      assert_no_difference("User.count") { get fourier_identity_path(format: :json) }
      assert_nil(session[:user_id])
    end

    should "make nothing when the switch is off" do
      Danbooru.config.stubs(:matrix_accounts_from_identity?).returns(false)

      assert_no_difference("User.count") { get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net") }
      assert_nil(session[:user_id])
    end
  end

  context "a returning Matrix user" do
    should "sign in the account linked to the identity, whatever its name" do
      user = create(:user, name: "renamed", matrix_id: "@alice:41chan.net")

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end

      assert_equal(user.id, session[:user_id])
      assert_equal(1, UserEvent.where(user: user, category: "login").count)
    end

    # Staff sign in the same way (operator, 2026-11-07: "It's no different for
    # them"). Rank is never consulted; two-factor sign-in is the one thing that
    # asks for more, at any rank (the two-factor context below).
    should "sign in a staff account the same way, at every rank" do
      [:moderator_user, :admin_user, :owner_user].each_with_index do |factory, i|
        user = create(factory, matrix_id: "@staff#{i}:41chan.net")
        reset!

        get fourier_identity_path(format: :json), headers: identity("@staff#{i}:41chan.net")

        assert_equal(user.id, session[:user_id], "expected #{factory} to be signed in by Matrix")
      end
    end

    should "not sign in a deleted account, nor make another under its old name" do
      create(:user, name: "gone", matrix_id: "@alice:41chan.net", is_deleted: true)

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_nil(session[:user_id])
    end
  end

  context "a Matrix username the booru cannot give out" do
    should "make nothing when an unlinked account holds the name" do
      create(:user, name: "alice")

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_nil(session[:user_id])
      assert_equal(false, response.parsed_body["signed_in"])
    end

    should "make nothing for a name the booru would refuse" do
      %w[a admin x.png user_12 aaaaaaaaaaaaaaaaaaaaaaaaa __a x=y].each do |localpart|
        assert_no_difference("User.count", "@#{localpart}:41chan.net") do
          get fourier_identity_path(format: :json), headers: identity("@#{localpart}:41chan.net")
        end
        assert_nil(session[:user_id], localpart)
      end
    end

    should "make nothing for an identity that is not a Matrix ID" do
      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("alice")
      end
    end

    should "say why on the login page, with the way on" do
      create(:user, name: "alice")
      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_response :success
      assert_select ".mxsign-account", text: /belongs to an existing account/
      assert_select ".mxsign-account a[href=?]", new_user_path(url: root_path)

      get login_path(preset: "modulation"), headers: identity("@x=y:41chan.net")
      assert_select ".mxsign-account", text: /can't be a booru name: it can't contain '='/
    end
  end

  context "a viewer already signed in" do
    should "stay signed in to an unlinked account under another name" do
      user = create(:user, name: "bob")
      login_as(user)

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_equal(user.id, session[:user_id])
      assert_nil(user.reload.matrix_id)
    end

    # Linked only when its owner asks, signing in (next context): a Matrix
    # sign-in someone else planted in this browser would otherwise take the
    # account its owner signs in to next.
    should "not link an unlinked account under the same name" do
      user = create(:user, name: "Alice")
      login_as(user)

      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_nil(user.reload.matrix_id)
      assert_equal(user.id, session[:user_id])
    end

    should "be signed out of an account linked to another identity, into this one's" do
      bob = create(:user, name: "bob", matrix_id: "@bob:41chan.net")
      login_as(bob)

      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal(User.find_by_name("alice").id, session[:user_id])
      assert_equal(1, UserEvent.where(user: bob, category: "logout").count)
    end

    should "keep the booru session when the identity goes away" do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal("alice", signed_in_name)
    end
  end

  context "signing in to the account that holds the Matrix username" do
    setup do
      @user = create(:user, name: "Alice", password: "alicepass")
    end

    should "be offered the link on the login page, unchecked" do
      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_select "input[type=checkbox][name='session[link_matrix]']"
      assert_select "input[type=checkbox][name='session[link_matrix]'][checked]", count: 0
      assert_select "label", text: /Link this account to your Matrix ID, @alice:41chan.net/
    end

    should "link it when asked" do
      post session_path, headers: identity("@alice:41chan.net"), params: { session: { name: "alice", password: "alicepass", link_matrix: "1" }}
      assert_equal(@user.id, session[:user_id])
      assert_equal("@alice:41chan.net", @user.reload.matrix_id)
    end

    should "not link it unasked, nor with the wrong password" do
      post session_path, headers: identity("@alice:41chan.net"), params: { session: { name: "alice", password: "alicepass" }}
      assert_equal(@user.id, session[:user_id])
      assert_nil(@user.reload.matrix_id)

      delete session_path
      post session_path, headers: identity("@alice:41chan.net"), params: { session: { name: "alice", password: "wrong", link_matrix: "1" }}
      assert_nil(@user.reload.matrix_id)
    end

    should "not take over a link another account holds" do
      create(:user, name: "first", matrix_id: "@alice:41chan.net")

      post session_path, headers: identity("@alice:41chan.net"), params: { session: { name: "alice", password: "alicepass", link_matrix: "1" }}
      assert_nil(@user.reload.matrix_id)
    end

    should "link it after the code, for an account with two-factor sign-in" do
      user = create(:user_with_2fa, name: "carol", password: "carolpass")

      post session_path, headers: identity("@carol:41chan.net"), params: { session: { name: "carol", password: "carolpass", link_matrix: "1" }}
      assert_nil(user.reload.matrix_id)
      user_id = css_select("input[name='totp[user_id]']").first["value"]

      post verify_totp_session_path, headers: identity("@carol:41chan.net"), params: { totp: { user_id: user_id, code: user.totp.code, link_matrix: "1" }}
      assert_equal(user.id, session[:user_id])
      assert_equal("@carol:41chan.net", user.reload.matrix_id)
    end
  end

  context "signing out of the booru while signed in to Matrix" do
    setup do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      delete session_path, headers: identity("@alice:41chan.net")
    end

    should "stay signed out" do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_nil(session[:user_id])
      assert_equal(false, response.parsed_body["signed_in"])
    end

    should "offer to continue on the login page" do
      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_select ".mxsign-account", text: /You signed out of your booru account, alice/
      assert_select ".mxsign-account a[href=?]", login_path(matrix: 1, url: root_path), text: "Continue as alice"
    end

    should "sign back in on continue" do
      get login_path(matrix: 1, url: "/posts"), headers: identity("@alice:41chan.net")
      assert_redirected_to "/posts"
      assert_nil(session[:matrix_signed_out])

      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal(User.find_by_name("alice").id, session[:user_id])
    end

    should "not hold back a different identity" do
      get fourier_identity_path(format: :json), headers: identity("@carol:41chan.net")
      assert_equal(User.find_by_name("carol").id, session[:user_id])
    end
  end

  # Technetium's Manage Session reads it to link the way on.
  context "the session status" do
    should "say the account and why it is not signed in" do
      create(:user, name: "alice")
      get modulation_session_status_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal({ "state" => "taken", "name" => "alice", "reason" => nil }, response.parsed_body.dig("booru", "account"))

      get modulation_session_status_path(format: :json), headers: identity("@x=y:41chan.net")
      assert_equal({ "state" => "invalid", "name" => "x=y", "reason" => "can't contain '='" }, response.parsed_body.dig("booru", "account"))
    end

    should "say a signed-out account by its name" do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      delete session_path, headers: identity("@alice:41chan.net")

      get modulation_session_status_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal("linked", response.parsed_body.dig("booru", "account", "state"))
      assert_equal("alice", response.parsed_body.dig("booru", "account", "name"))
    end

    should "say nothing of it once signed in, or without an identity" do
      get modulation_session_status_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal(true, response.parsed_body.dig("booru", "signed_in"))
      assert_nil(response.parsed_body.dig("booru", "account"))

      reset!
      get modulation_session_status_path(format: :json)
      assert_nil(response.parsed_body.dig("booru", "account"))
    end
  end

  context "a viewer signed out of the booru with no account linked" do
    should "be offered the same-name account on the login page" do
      bob = create(:user, name: "bob")
      login_as(bob)
      delete session_path, headers: identity("@alice:41chan.net")

      assert_no_difference("User.count") { get login_path(preset: "modulation"), headers: identity("@alice:41chan.net") }
      assert_select ".mxsign-account a[href=?]", login_path(matrix: 1, url: root_path),
                    text: "Create your booru account with the same name as your Matrix username, alice"
    end
  end

  context "the identity header" do
    teardown { FourierIdentity.instance_variable_set(:@proxy_addresses, nil) }

    should "be honoured from the proxy" do
      Danbooru.config.stubs(:fourier_identity_proxy).returns("proxy.test")
      Resolv.stubs(:getaddresses).with("proxy.test").returns(["127.0.0.1"])

      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_equal("@alice:41chan.net", response.parsed_body["matrix_id"])
      assert_equal(true, response.parsed_body["signed_in"])
    end

    should "be ignored from any other peer, and say so without the identity" do
      Danbooru.config.stubs(:fourier_identity_proxy).returns("proxy.test")
      Resolv.stubs(:getaddresses).with("proxy.test").returns(["10.9.9.9"])
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with { |line| line.include?("not the proxy \"proxy.test\"") && line.exclude?("alice") }.at_least_once

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_equal(false, response.parsed_body["linked"])
      assert_nil(session[:user_id])
    end

    should "be judged once a request, however often it is read" do
      Danbooru.config.stubs(:fourier_identity_proxy).returns("proxy.test")
      Resolv.expects(:getaddresses).with("proxy.test").once.returns(["10.9.9.9"])
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with { |line| line.include?("not the proxy") }.once

      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_response :success
    end

    should "say so when the proxy's name resolves to nothing" do
      Danbooru.config.stubs(:fourier_identity_proxy).returns("proxy.test")
      Resolv.stubs(:getaddresses).with("proxy.test").returns([])
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with { |line| line.include?("resolves to no address") && line.include?("fourier_identity_proxy") }.at_least_once

      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_nil(session[:user_id])
    end
  end

  context "an account with two-factor sign-in" do
    setup do
      @alice = create(:user_with_2fa, name: "alice", matrix_id: "@alice:41chan.net")
    end

    should "not be signed in by the Matrix sign-in alone" do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      assert_nil(session[:user_id])
    end

    # Its password is random when the account was made for the Matrix ID
    # (MatrixAccount#create), so the Matrix sign-in stands in for it and the
    # code is still asked, as in change password and reauthentication.
    should "be signed in with the Matrix sign-in and its code, as the login page says" do
      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_select ".mxsign-account a.mxsign-continue[href=?]", login_path(matrix: 1, url: root_path), text: "Continue as alice with your two-factor code"

      get login_path(matrix: 1, url: "/posts"), headers: identity("@alice:41chan.net")
      assert_nil(session[:user_id])
      user_id = css_select("input[name='totp[user_id]']").first["value"]

      post verify_totp_session_path, headers: identity("@alice:41chan.net"), params: { totp: { user_id: user_id, code: @alice.totp.code, url: "/posts" }}
      assert_redirected_to "/posts"
      assert_equal(@alice.id, session[:user_id])
    end

    should "not be asked for its code without the Matrix sign-in" do
      get login_path(matrix: 1, url: "/posts")
      assert_redirected_to "/posts"
      assert_nil(session[:user_id])
    end

    should "be deleted with its code, not with the Matrix sign-in alone" do
      login_as(@alice)

      delete user_path(@alice), headers: identity("@alice:41chan.net")
      assert_equal(false, @alice.reload.is_deleted)

      get deactivate_user_path(@alice), headers: identity("@alice:41chan.net")
      assert_select "input[name='user[password]']", count: 0
      assert_select "input[name='user[verification_code]']"

      delete user_path(@alice), headers: identity("@alice:41chan.net"), params: { user: { verification_code: @alice.totp.code }}
      assert_equal(true, @alice.reload.is_deleted)
    end
  end

  context "deleting the account while signed in to Matrix" do
    setup do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      @alice = User.find_by_name("alice")
    end

    should "need no password, and not make the account again on the next request" do
      delete user_path(@alice), headers: identity("@alice:41chan.net")
      assert_equal(true, @alice.reload.is_deleted)

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_nil(session[:user_id])

      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_select ".mxsign-account a[href=?]", login_path(matrix: 1, url: root_path),
                    text: "Create your booru account with the same name as your Matrix username, alice"
    end

    should "still need the password without the Matrix sign-in" do
      delete user_path(@alice)
      assert_equal(false, @alice.reload.is_deleted)
    end
  end

  # Deleted by the site staff, it stays deleted: the next request neither signs
  # it in nor makes a new account under the freed name, and the deletion can
  # still be undone (UserDeletion#undelete! gives the name back).
  context "an account the Owner deleted" do
    setup do
      @alice = create(:user, name: "alice", password: "alicepass", matrix_id: "@alice:41chan.net")
      @owner = create(:owner_user)
      UserDeletion.new(user: @alice, deleter: @owner).delete!
    end

    should "stay linked, not be made again, and be restorable" do
      assert_equal("@alice:41chan.net", @alice.reload.matrix_id)

      assert_no_difference("User.count") do
        get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      end
      assert_nil(session[:user_id])

      UserDeletion.new(user: @alice, deleter: @owner, password: "alicepass").undelete!
      assert_equal("alice", @alice.reload.name)
    end

    should "say so on the login page, with the way on" do
      get login_path(preset: "modulation"), headers: identity("@alice:41chan.net")
      assert_select ".mxsign-account", text: /Your booru account was deactivated by the site staff/
      assert_select ".mxsign-account a.mxsign-continue", count: 0
    end
  end

  # The account's password is random and nobody was told it (MatrixAccount#create).
  context "the Matrix sign-in in place of the password" do
    setup do
      get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
      @alice = User.find_by_name("alice")
    end

    should "change the password" do
      put user_password_path(@alice), headers: identity("@alice:41chan.net"), params: { user: { password: "newpass1", password_confirmation: "newpass1" }}
      assert(@alice.reload.authenticate_password("newpass1"))

      get edit_user_password_path(@alice), headers: identity("@alice:41chan.net")
      assert_select "input[name='user[current_password]']", count: 0
    end

    should "reauthenticate, and leave the password out of the deactivation form" do
      get confirm_password_session_path, headers: identity("@alice:41chan.net")
      assert_select "input[name='session[password]']", count: 0

      post reauthenticate_session_path, headers: identity("@alice:41chan.net"), params: { session: { url: "/posts" }}
      assert_redirected_to "/posts"
      assert_not_nil(session[:last_authenticated_at])

      get deactivate_user_path(@alice), headers: identity("@alice:41chan.net")
      assert_select "input[name='user[password]']", count: 0
    end

    should "not stand in for it without the identity, nor for an account not linked to it" do
      put user_password_path(@alice), params: { user: { password: "newpass1", password_confirmation: "newpass1" }}
      assert_not(@alice.reload.authenticate_password("newpass1"))

      bob = create(:user, name: "bob", password: "bobpass1")
      assert_equal(false, bob.matrix_verified?(ActionDispatch::TestRequest.create(FourierIdentity::HEADER => "@alice:41chan.net")))
    end
  end

  context "a new name that is someone's Matrix username" do
    should "be refused at signup to anyone but its owner, and asked about by Matrix ID" do
      Danbooru::Http.any_instance.expects(:get).with("https://chat.example/_matrix/client/v3/profile/%40bob%3A41chan.net").at_least_once.returns(stub(code: 200))

      assert_no_difference("User.count") do
        post users_path, headers: identity("@x=y:41chan.net"), params: { user: { name: "Bob", password: "hunter22", password_confirmation: "hunter22" }}
      end
      assert_match(/belongs to a 41chan Matrix account/, response.body)
    end

    should "be refused when the homeserver cannot say, and the log says what to fix" do
      Danbooru::Http.any_instance.stubs(:get).returns(stub(code: 401))
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with { |line| line.include?("HTTP 401") && line.include?("DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN") && line.exclude?("syt_reader") }

      assert_no_difference("User.count") do
        post users_path, headers: identity("@x=y:41chan.net"), params: { user: { name: "bob", password: "hunter22", password_confirmation: "hunter22" }}
      end
      assert_match(/can&#39;t be checked against 41chan Matrix usernames right now/, response.body)
    end

    should "not be asked about when no Matrix username can be it" do
      Danbooru::Http.any_instance.expects(:get).never

      assert_difference("User.count", 1) do
        post users_path, headers: identity("@x=y:41chan.net"), params: { user: { name: "\u30DC\u30D6", password: "hunter22", password_confirmation: "hunter22" }}
      end
    end

    should "be refused as a new name for an account" do
      carol = create(:user, name: "carol")
      Danbooru::Http.any_instance.stubs(:get).returns(stub(code: 200))

      request = UserNameChangeRequest.new(user: carol, original_name: "carol", desired_name: "bob")
      assert_equal(false, request.save)
      assert_match(/belongs to a 41chan Matrix account/, request.errors.full_messages.join)
    end
  end

  context "choosing another name at signup" do
    setup do
      Danbooru.config.stubs(:enable_signup?).returns(false)
    end

    should "need no invite code, and link the verified identity, not a param" do
      get new_user_path, headers: identity("@x=y:41chan.net")
      assert_response :success
      assert_select "input[name='user[signup_token]']", count: 0

      assert_difference("User.count", 1) do
        post users_path, headers: identity("@x=y:41chan.net"), params: {
          user: { name: "chosen", password: "hunter22", password_confirmation: "hunter22", matrix_id: "@someone:41chan.net" },
        }
      end

      assert_equal("@x=y:41chan.net", User.find_by_name("chosen").matrix_id)
    end

    should "still need an invite code without an identity" do
      assert_no_difference("User.count") do
        post users_path, params: { user: { name: "chosen", password: "hunter22", password_confirmation: "hunter22" }}
      end
      assert_response 403
    end
  end

  # 41chan keeps no email addresses (operator, 2026-11-07): retired, the field
  # is not asked for and an address sent anyway is not kept.
  context "with emails retired" do
    setup do
      Danbooru.config.stubs(:retired_sections).returns(%w[emails])
    end

    should "not ask for an email at signup, nor keep one sent" do
      get new_user_path
      assert_select "input[name='user[email_address][address]']", count: 0

      assert_no_difference("EmailAddress.count") do
        post users_path, params: { user: { name: "walkin", password: "hunter22", password_confirmation: "hunter22", email_address: { address: "walkin@example.com" }}}
      end
      assert_not_nil(User.find_by_name("walkin"))
    end

    should "not ask for one in the account settings" do
      user = create(:user)
      get_auth edit_user_path(user), user
      assert_select "input[name='user[email_address][address]']", count: 0
    end

    # The Owner is exempt from a retired section, so the record refuses it too.
    should "keep none the Owner sends, for themselves or for another account" do
      owner = create(:owner_user)
      user = create(:user)

      assert_no_difference("EmailAddress.count") do
        put_auth user_email_path(owner), owner, params: { email_address: { address: "owner@example.com" }}
        put_auth user_email_path(user), owner, params: { email_address: { address: "walkin@example.com" }}
      end
      assert_equal(false, ModAction.exists?(category: "email_address_update"))
    end

    should "not offer the Owner a change of email on the admin page" do
      owner = create(:owner_user)
      get_auth edit_admin_user_path(create(:user)), owner
      assert_select "a", text: "Change email", count: 0
    end
  end

  should "not tell a Restricted account to verify an email" do
    get fourier_identity_path(format: :json), headers: identity("@alice:41chan.net")
    get posts_path
    assert_select "#verify-account-notice", count: 0
  end

  context "MatrixAccount#create" do
    should "hand back the account a concurrent request made" do
      account = MatrixAccount.new(ActionDispatch::TestRequest.create, "@alice:41chan.net")
      assert_equal("available", account.state)
      winner = create(:user, name: "alice", matrix_id: "@alice:41chan.net")

      assert_equal(winner, account.create)
    end

    should "raise when the account was refused for anything else" do
      account = MatrixAccount.new(ActionDispatch::TestRequest.create, "@alice:41chan.net")
      assert_equal("available", account.state)
      create(:user, name: "alice")

      assert_raises(ActiveRecord::RecordInvalid) { account.create }
    end
  end
end
