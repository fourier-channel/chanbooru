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

      should "show mods all events by lower-level users and themselves" do
        @mod = create(:moderator_user)
        create(:user_event, user: @mod, category: :login)

        get_auth user_events_path, @mod

        assert_response :success
        assert_select "tbody tr", count: UserEvent.count
      end

      should "not show mods events by users of the same or higher level" do
        @mod = create(:moderator_user)
        create(:user_event, user: create(:moderator_user), category: :login)
        create(:user_event, user: create(:admin_user), category: :login)

        get_auth user_events_path, @mod, as: :json

        assert_response :success
        assert_equal([@user.id, @user2.id, @mod.id].sort, response.parsed_body.pluck("user_id").uniq.sort)
      end

      should "not show admins events by the owner" do
        @owner = create(:owner_user)
        create(:user_event, user: @owner, category: :login)

        get_auth user_events_path, create(:admin_user), as: :json

        assert_response :success
        assert_not_includes(response.parsed_body.pluck("user_id"), @owner.id)
      end

      should "not show mods higher-level users in the list of sockpuppet accounts" do
        @mod = create(:moderator_user)
        @admin = create(:admin_user, name: "sockpuppet_admin")
        @user3 = create(:user, name: "sockpuppet_user")
        session_id = @user.user_events.first.session_id
        create(:user_event, user: @admin, category: :login, session_id: session_id)
        create(:user_event, user: @user3, category: :login, session_id: session_id)

        get_auth user_events_path(user_id: @user.id, mode: "table"), @mod

        assert_response :success
        assert_match(/sockpuppet_user/, response.body)
        assert_no_match(/sockpuppet_admin/, response.body)
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
