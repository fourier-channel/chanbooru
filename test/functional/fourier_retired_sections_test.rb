require "test_helper"

# Comments, notes and the forum are retired (operator ruling 2026-09-06): gone
# from the header, and gone from the site for everyone but the owner.
#
# The header half is cosmetic and was never the point. A link removed from a nav
# is not a page that is gone -- the URL still worked, the JSON API still
# answered, and the write actions still accepted. These tests are about the
# other half.
#
# 404, specifically, and for the same reason a hidden post is a 404: a 403 would
# confirm there is something behind the door.
class FourierRetiredSectionsTest < ActionDispatch::IntegrationTest
  RETIRED_HTML = %w[/comments /notes /forum_topics /forum_posts /comment_votes /note_versions /media_assets /ai_tags].freeze
  RETIRED_JSON = %w[/comments.json /notes.json /forum_topics.json /media_assets.json /ai_tags.json].freeze

  # Danbooru.config.retired_sections is EMPTY under Rails.env.test?, so the
  # inherited suite keeps measuring upstream's behaviour -- forum_posts_controller_test
  # alone signs in as an ordinary user 45 times and expects the forum to
  # answer. The restriction is switched ON here, which makes this file the only
  # place it is asserted, and therefore the place it has to be asserted
  # thoroughly.
  SECTIONS = %w[
    comments comment_votes
    forum_topics forum_posts forum_post_votes forum_topic_visits
    notes note_versions
    media_assets ai_tags
  ].freeze

  def retire!
    Danbooru.config.stubs(:retired_sections).returns(SECTIONS)
  end

  context "a retired section" do
    setup { retire! }

    should "404 for an anonymous visitor" do
      RETIRED_HTML.each do |path|
        get path
        assert_response 404, "expected #{path} to 404 for anonymous"
      end
    end

    # The API was the hole in the version of this guard that shipped upstream:
    # it checked request.format.html?, so .json answered in full.
    should "404 on the API too, not only on the page" do
      RETIRED_JSON.each do |path|
        get path
        assert_response 404, "expected #{path} to 404 for anonymous"
      end
    end

    should "404 for an ordinary member" do
      user = create(:user)

      RETIRED_HTML.each do |path|
        get_auth path, user
        assert_response 404, "expected #{path} to 404 for a member"
      end
    end

    should "404 for a moderator, who is not the owner" do
      get_auth "/comments", create(:moderator_user)
      assert_response 404
    end

    # The records are still there and still worth being able to look at. Losing
    # access to the archive was never the ask.
    should "stay open to the owner" do
      owner = create(:owner_user)

      get_auth "/comments", owner
      assert_response :success

      get_auth "/notes", owner
      assert_response :success

      get_auth "/forum_topics", owner
      assert_response :success

      get_auth "/media_assets", owner
      assert_response :success

      get_auth "/ai_tags", owner
      assert_response :success
    end

    # media_assets (2026-09-30): a file's page and its bytes route are the same
    # section, so knowing an id is no way in either.
    should "404 a media asset's own page and image route for anyone but the owner" do
      asset = create(:media_asset)
      [nil, create(:user), create(:moderator_user)].each do |viewer|
        [media_asset_path(asset), media_asset_path(asset, format: :json), media_asset_image_path(asset, "original")].each do |path|
          viewer ? get_auth(path, viewer) : get(path)
          assert_response 404, "expected #{path} to 404 for #{viewer&.name || "anonymous"}"
        end
      end
    end
  end

  context "the sections that are NOT retired" do
    setup { retire! }

    should "still answer" do
      get "/posts"
      assert_response :success

      get "/tags"
      assert_response :success
    end

    # "commentary" is not "comments": it is a post's own description, and
    # retiring it would blank part of the post page. Named here because the
    # controller list is matched on controller_name and the near-miss is easy.
    should "leave artist commentary alone" do
      get "/artist_commentaries"
      assert_response :success
    end

    # upload_media_assets is not media_assets: an uploader's own upload page
    # must keep working. Named for the same near-miss reason as commentary.
    should "leave a member's own uploads alone" do
      user = create(:user)
      get_auth user_uploads_path(user), user
      assert_response :success
    end
  end

  # The standalone /logout page goes the same way. The real logout --
  # DELETE /session -- must NOT, or the header's Log Out button stops working
  # for everyone, so that is asserted here too.
  context "the retired logout page" do
    setup { Danbooru.config.stubs(:logout_page_retired?).returns(true) }

    should "404 for an ordinary member" do
      get_auth logout_path, create(:user)

      assert_response 404
    end

    should "404 for an anonymous visitor" do
      get logout_path

      assert_response 404
    end

    should "stay open to the owner" do
      get_auth logout_path, create(:owner_user)

      assert_response :success
    end

    should "leave the actual logout working for everyone" do
      user = create(:user)

      delete_auth session_path, user

      assert_redirected_to root_path
      assert_nil(session[:user_id])
    end

    # /login is NOT retired: the app redirects ordinary users there from
    # password reset, settings, upload and access-denied. If this ever starts
    # 404ing, those recovery paths are broken.
    should "leave the login page reachable" do
      get login_path

      assert_response :success
    end
  end

  # Without this, the fork's restriction would silently start applying to the
  # whole inherited suite the moment someone dropped the Rails.env.test? guard,
  # and 45 forum tests would go red with a 404 that looks like a routing bug.
  context "the retirement switch" do
    should "be off in the test environment, so the inherited suite still measures upstream" do
      assert_equal([], Danbooru.config.retired_sections)

      get "/forum_topics"
      assert_response :success
    end
  end
end
