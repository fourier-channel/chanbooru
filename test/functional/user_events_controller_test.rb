require "test_helper"

class UserEventsControllerTest < ActionDispatch::IntegrationTest
  context "The user events controller" do
    context "index action" do
      setup do
        @user = create(:user)
        create(:user_event, user: @user, category: :login)
        create(:user_event, user: @user, category: :password_change)
        create(:user_event, user: @user, category: :logout)

        @user2 = create(:user)
        create(:user_event, user: @user2, category: :password_reset_request)
        create(:user_event, user: @user2, category: :password_reset)
      end

      should "render" do
        get_auth user_events_path, @user
        assert_response :success
      end

      # IpDataPruner nulls an old event's address, user agent and session id
      # and keeps the event (operator, 2026-11-01), so the account history
      # draws it with no network identity.
      context "with an event the IP pruner has cleared" do
        setup do
          create(:user_event, user: @user, category: :login, created_at: IpDataPruner::MAX_AGE.ago - 1.day)
          PruneIpDataJob.perform_now
          assert(UserEvent.exists?(user: @user, ip_addr: nil, session_id: nil, user_agent: nil))
        end

        should "render it for the owner and a moderator, as a list and as a table" do
          [@user, create(:moderator_user)].product(%w[list table]).each do |viewer, mode|
            get_auth user_events_path(mode: mode, search: { user_id: @user.id }), viewer
            assert_response :success, "#{mode} for #{viewer.level_string}"
          end
        end
      end

      should "show mods all events" do
        get_auth user_events_path, create(:moderator_user)

        assert_response :success
        assert_select "tbody tr", count: UserEvent.count
      end

      should "show users their own events" do
        get_auth user_events_path, @user

        assert_response :success
        assert_select "tbody tr", count: @user.user_events.count
      end

      should "not show users events belonging to other users" do
        get_auth user_events_path(search: { user_id: @user.id }), @user2

        assert_response :success
        assert_select "tbody tr", count: 0
      end

      should "not show anonymous users any events" do
        get user_events_path

        assert_response :success
        assert_select "tbody tr", count: 0
      end
    end
  end
end
