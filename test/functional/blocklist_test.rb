require "test_helper"

# The blocklist (operator, 2026-10-13): the person's own list is the only
# filter. One control, joined to the purge/refresh rectangle in the header of
# every page; its pills are added, removed, locked and unlocked through the
# existing PATCH /modulation/settings door; the signed-in list lives on the
# account and other apps read it from GET /profile.json.
class BlocklistFunctionalTest < ActionDispatch::IntegrationTest
  def blocklist_patch(op, rule = nil, **extra)
    patch modulation_settings_path, params: { blocklist: { op: op, rule: rule, **extra }}, as: :json
  end

  def blocks
    response.parsed_body["blocklist"].map { |b| [b["rule"], b["locked"]] }
  end

  context "The blocklist" do
    setup do
      @user = travel_to(1.month.ago) { create(:user, blacklisted_tags: "cat") }
      @post = as(@user) { create(:post, tag_string: "aaaa bbbb") }
    end

    context "edited through PATCH /modulation/settings" do
      context "by a member" do
        setup { login_as(@user) }

        should "add, lock, refuse a locked removal, unlock and remove" do
          blocklist_patch("add", "Spider")
          assert_response :success
          assert_equal([["cat", false], ["spider", false]], blocks)

          blocklist_patch("lock", "spider")
          assert_equal([["cat", false], ["spider", true]], blocks)
          assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

          blocklist_patch("remove", "spider")
          assert_response 422
          assert_equal("'spider' is locked. Unlock it first (the padlock on its pill), then remove it.", response.parsed_body["error"])
          assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

          blocklist_patch("unlock", "spider")
          blocklist_patch("remove", "spider")
          assert_response :success
          assert_equal([["cat", false]], blocks)
          assert_equal("cat", @user.reload.blacklisted_tags)
        end

        should "merge a signed-out list into the account, adding only" do
          blocklist_patch("merge", nil, blocks: [{ rule: "spider", locked: true }, { rule: "cat", locked: false }])

          assert_response :success
          assert_equal([["cat", false], ["spider", true]], blocks)
          assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)
        end

        should "refuse a malformed edit with the shape it wants" do
          patch modulation_settings_path, params: { blocklist: "spider" }, as: :json
          assert_response 422
          assert_match(/"op": "add"/, response.parsed_body["error"])
        end

        should "leave the view settings alone" do
          blocklist_patch("add", "spider")
          assert_not response.parsed_body.key?("image_cap")
        end
      end

      context "by a signed-out viewer" do
        should "apply the op to the browser's own list and store nothing on the server" do
          blocklist_patch("add", "Spider", list: [{ rule: "dog", locked: true }])

          assert_response :success
          assert_equal([["dog", true], ["spider", false]], blocks)
          assert_nil(session[:blocklist])

          blocklist_patch("remove", "dog", list: [{ rule: "dog", locked: true }])
          assert_response 422
          assert_match(/'dog' is locked/, response.parsed_body["error"])
        end
      end
    end

    context "in the header" do
      should "sit in the corner, joined to the purge rectangle, once per page" do
        as(@user) { create(:pool, post_ids: [@post.id]) }
        checked = []
        [nil, @user].each do |viewer|
          [posts_path, post_path(@post), root_path, user_path(@user), gallery_pools_path].each do |path|
            get_auth path, viewer, params: { preset: "modulation" } if viewer
            get path, params: { preset: "modulation" } unless viewer
            next if response.redirect? || response.not_found?

            label = "#{path} as #{viewer&.name || "signed out"}"
            assert_select "#blacklist-box", 1, label
            assert_select ".modnav-corner > #blacklist-box + .modnav-reset", 1, label
            assert_select ".modland-blacklist", 0, label
            assert_select ".blacklist-enforced, .blacklist-censor", 0, label
            checked << label
          end
        end
        # A page that redirects (a members-only listing, signed out) is
        # skipped above; this keeps the skip from emptying the test.
        assert_operator checked.size, :>=, 8, checked.inspect
      end

      should "render in the historical header too" do
        get_auth posts_path, @user, params: { preset: "historical" }

        assert_response :success
        assert_select "header#top #blacklist-box", 1
        assert_select "#blacklist-box", 1
      end

      should "send only the viewer's own rules to the page" do
        get_auth posts_path, @user, params: { preset: "modulation" }

        init = css_select("#blacklist-box").first["x-init"]
        assert_equal([{ "rule" => "cat", "locked" => false }], JSON.parse(init[/\Ablacklist\.initialize\((\[.*\]),/m, 1]))
      end
    end

    context "read by another app" do
      should "come back parsed on the viewer's own /profile.json and on no one else's" do
        @user.update!(blacklisted_tags: "cat\nspider %locked")
        other = create(:user, blacklisted_tags: "secret")

        get_auth profile_path(format: :json), @user
        assert_response :success
        assert_equal([{ "rule" => "cat", "locked" => false }, { "rule" => "spider", "locked" => true }], response.parsed_body["blocklist"])

        get_auth user_path(other, format: :json), @user
        assert_response :success
        assert_not response.parsed_body.key?("blocklist")
        assert_not response.parsed_body.key?("blacklisted_tags")

        get_auth user_path(other, format: :json), @user, params: { only: "id,blocklist,blacklisted_tags" }
        assert_equal(["id"], response.parsed_body.keys)
      end

      should "come back on /profile.xml too, without breaking it" do
        @user.update!(blacklisted_tags: "cat\nspider %locked")

        get_auth profile_path(format: :xml), @user
        assert_response :success
        blocks = Hash.from_xml(response.body).dig("user", "blocklist")
        assert_equal([{ "rule" => "cat", "locked" => false }, { "rule" => "spider", "locked" => true }], blocks)
      end

      should "answer a signed-out request with an empty list and no one's text" do
        get profile_path(format: :json)
        assert_response :success
        assert_equal([], response.parsed_body["blocklist"])
        assert_equal("", response.parsed_body["blacklisted_tags"].to_s)
      end
    end

    context "edited as text on the settings page" do
      should "refuse dropping a locked line, and save once it is unlocked" do
        @user.update!(blacklisted_tags: "cat\nspider %locked")

        put_auth user_path(@user), @user, params: { user: { blacklisted_tags: "cat" }}
        assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

        put_auth user_path(@user), @user, params: { user: { blacklisted_tags: "cat\nspider" }}
        put_auth user_path(@user), @user, params: { user: { blacklisted_tags: "cat" }}
        assert_equal("cat", @user.reload.blacklisted_tags)
      end

      should "refuse an API write that drops a locked line, and say how to unlock" do
        @user.update!(blacklisted_tags: "cat\nspider %locked")

        put_auth user_path(@user, format: :json), @user, params: { user: { blacklisted_tags: "cat" }}
        assert_response 422
        assert_match(/'spider': it is locked/, response.body)
        assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

        put_auth user_path(@user, format: :json), @user, params: { user: { blacklisted_tags: "" }}
        assert_response 422
        assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)
      end

      should "word the hint as a sentence a person can read" do
        get_auth edit_user_path(@user), @user

        hint = css_select(".user_blacklisted_tags .hint").text
        assert_match(/\APosts these blocks match are hidden on every page/, hint)
      end

      should "label the field Blocklist" do
        get_auth edit_user_path(@user), @user

        assert_response :success
        assert_select "label[for=user_blacklisted_tags]", text: "Blocklist"
        assert_no_match(/blacklist/i, css_select("#a-edit").text)
      end
    end
  end
end
