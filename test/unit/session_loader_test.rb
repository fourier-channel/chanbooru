require "test_helper"

class SessionLoaderTest < ActiveSupport::TestCase
  context "SessionLoader" do
    setup do
      @request = mock
      @request.stubs(:host).returns("danbooru")
      @request.stubs(:remote_ip).returns("127.0.0.1")
      @request.stubs(:path).returns("/")
      @request.stubs(:authorization).returns(nil)
      @request.stubs(:cookie_jar).returns({})
      @request.stubs(:cookies).returns({})
      @request.stubs(:parameters).returns({})
      @request.stubs(:query_parameters).returns({})
      @request.stubs(:session).returns({})
      @request.stubs(:headers).returns({})
      SessionLoader.any_instance.stubs(:initialize_session_cookies)
    end

    teardown do
      CurrentUser.user = nil
      CurrentUser.safe_mode = nil
    end

    context ".load" do
      should "not log in a session without a login session" do
        @user = create(:user)
        @request.stubs(:session).returns({ user_id: @user.id })
        UserEvent.expects(:create_from_request!).never
        User.any_instance.expects(:with_lock).never
        SessionLoader.new(@request).load

        assert_equal(true, CurrentUser.user.is_anonymous?)
        assert_nil(@request.session[:user_id])
      end
    end

    context ".safe_mode?" do
      should "return true if the hostname is safebooru.donmai.us" do
        @request.stubs(:host).returns("safebooru.donmai.us")
        SessionLoader.new(@request).load

        assert_equal(true, CurrentUser.safe_mode?)
      end

      should "return false if the host contains the string danbooru" do
        @request.stubs(:host).returns("danbooru")
        SessionLoader.new(@request).load

        assert_equal(false, CurrentUser.safe_mode?)
      end

      should "return true if the user has enabled the safe mode account setting" do
        @user = create(:user, enable_safe_mode: true)
        @login_session = create(:login_session, user: @user)
        @request.stubs(:session).returns(user_id: @user.id, login_id: @login_session.login_id)
        SessionLoader.new(@request).load

        assert_equal(true, CurrentUser.safe_mode?)
      end

      context "for a viewer signed out, with the default-deny rule in force" do
        setup do
          Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
          @request.stubs(:get_header).returns(nil)
          @request.stubs(:remote_addr).returns("10.0.0.5")
          MediaDoorAsk.instance_variable_set(:@door_addresses, nil) # its lookup is kept between requests
        end

        should "be on: signed-out viewers see rating g only" do
          SessionLoader.new(@request).load

          assert_equal(true, CurrentUser.safe_mode?)
        end

        should "be off for a signed-in member" do
          @user = create(:user)
          @request.stubs(:session).returns(user_id: @user.id)
          SessionLoader.new(@request).load

          assert_equal(false, CurrentUser.safe_mode?)
        end

        should "be off for a verified Matrix identity" do
          @request.stubs(:get_header).with(FourierIdentity::HEADER).returns("@bob:41chan.net")
          @request.stubs(:get_header).with("fourier_identity.from_proxy").returns(true)
          @request.stubs(:has_header?).returns(true)
          SessionLoader.new(@request).load

          assert_equal(false, CurrentUser.safe_mode?)
        end

        should "stay on for the retired token-holder ask, even from the media door" do
          Danbooru.config.stubs(:fourier_media_door).returns("fourier-auth")
          Resolv.stubs(:getaddresses).with("fourier-auth").returns(["10.0.0.5"])
          @request.stubs(:query_parameters).returns({ "media_door" => "token_holder" })
          SessionLoader.new(@request).load

          assert_equal(true, CurrentUser.safe_mode?)
        end
      end

      should "not raise if the request has no remote ip" do
        @request.stubs(:remote_ip).returns(nil)

        assert_nothing_raised do
          SessionLoader.new(@request).load
        end
      end
    end
  end
end
