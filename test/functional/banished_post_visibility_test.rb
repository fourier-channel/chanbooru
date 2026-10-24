# frozen_string_literal: true

require "test_helper"

# A post carrying the jail tag or a banished tag is withheld from everyone
# but the pipeline (operator, 2026-09-24: such a post "is supposed to
# immediately disappear from the booru view surface"). Admins included, with
# no toggle (operator, relayed 2026-10-12: "We're also going to be removing
# the Admin-only 'reveal' option--the booru itself will never be the surface
# that shows banished tags, ever.").
#
# The rule is off under test (Danbooru.config.banished_posts_withheld?, the
# fork restriction pattern) and asserted here with it stubbed on, in the
# production shape: deleted posts visible from ADMIN up, as in production.
class BanishedPostVisibilityTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  JAIL = "troll_jail"
  BOARD = "https://boards.4chan.org/b/thread/953493575#p953493576"

  # Jailed by the booru itself on arrival (Post#jail_on_banished_tags).
  def jailed_post(user)
    as(user) { create(:post, tag_string: "landscape gore", source: BOARD, uploader: user, md5: SecureRandom.hex(16)) }.reload
  end

  # Jailed, then released the way fourier-sampling releases: undeleted, then
  # the jail tag taken off. Live, and still carrying its banished tag.
  def released_post(user)
    post = jailed_post(user)
    as(user) do
      post.update!(is_deleted: false)
      post.update!(tag_string: (post.tag_array - [JAIL]).join(" "))
    end
    post.reload
  end

  def search_ids(user, tags)
    get_auth posts_path(format: :json), user, params: { tags: tags, limit: 100 }
    assert_response :success
    response.parsed_body.pluck("id")
  end

  def landing_ids(viewer)
    LandingShowcase.new(viewer: viewer).categories
                   .find { |c| c[:key] == "new" }.to_h[:slides].to_a.pluck(:id)
  end

  # Every rule the blocklist engine is initialised with on this page. Since
  # 2026-10-13 that is the viewer's own list and nothing else: the enforced
  # list is gone, and the server's withholding is the gate.
  def rules_on_page
    init = css_select("#blacklist-box").first&.attribute("x-init")&.value.to_s
    JSON.parse(init[/\Ablacklist\.initialize\((\[.*\]),/m, 1] || "[]").pluck("rule")
  end

  context "With the rule on" do
    setup do
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      banish_tags!("gore")

      # An approver, as the sampling bot is: below contributor, a deleted
      # upload counts against the upload limit, and every jailing is one.
      @uploader = create(:approver_user)
      @jailed = jailed_post(@uploader)
      @released = released_post(@uploader)
      # troll_jail on a live post: a jailing whose delete half never landed.
      # md5s as the booru holds them, 32 hex: the factory's default is longer,
      # and an md5: search -- the media gate's question, the bot's lookup --
      # matches nothing for it, which would pass a "not found" check vacuously.
      @half_jailed = as(@uploader) { create(:post, tag_string: "landscape #{JAIL}", source: BOARD, uploader: @uploader, md5: SecureRandom.hex(16)) }
      @plain = as(@uploader) { create(:post, tag_string: "landscape", source: BOARD, uploader: @uploader, md5: SecureRandom.hex(16)) }
      @deleted = as(@uploader) { create(:post, tag_string: "landscape", source: BOARD, uploader: @uploader) }
      @deleted.update!(is_deleted: true)

      @admin = create(:admin_user)
      @member = create(:user)

      assert @jailed.is_deleted? && @jailed.has_tag?(JAIL), "fixture: the booru jails a post created with gore"
      assert_not @released.is_deleted?, "fixture: the released post is live"
    end

    # THE HALF THAT WAS MISSING (2026-10-12). Until then the rule withheld
    # these posts from admins only and left everyone else to the deletion, so
    # the two LIVE ones -- released, and half-jailed -- were hidden from an
    # admin and served to a member, a moderator and a signed-out reader. The
    # setup built @member and nothing asked it.
    context "a member, a moderator and a signed-out reader" do
      setup do
        @moderator = create(:moderator_user)
      end

      should "get a 404 from the post page of a live banished-tagged or jailed post" do
        [@member, @moderator].each do |viewer|
          [@released, @half_jailed].each do |post|
            get_auth post_path(post), viewer
            assert_response 404, "#{viewer.level_string} on post ##{post.id} (#{post.tag_string})"
          end
          get_auth post_path(@plain), viewer
          assert_response :success, "#{viewer.level_string} still reaches an ordinary post"
        end
      end

      should "not find them in a search, or in its count" do
        [@member, @moderator].each do |viewer|
          ids = search_ids(viewer, "landscape")
          assert_includes ids, @plain.id
          assert_not_includes ids, @released.id, viewer.level_string
          assert_not_includes ids, @half_jailed.id, viewer.level_string
          assert_empty search_ids(viewer, "gore"), viewer.level_string
        end
      end

      # The question fourier-auth's media gate asks, signed out, before it
      # releases an image: an empty answer is a refused image.
      should "answer the media gate's signed-out md5 ask with nothing" do
        [@released, @half_jailed].each do |post|
          get posts_path(format: :json), params: { tags: "md5:#{post.md5}", only: "md5,is_deleted,source", limit: 1 }
          assert_response :success
          assert_empty response.parsed_body, "post ##{post.id} (#{post.tag_string})"
        end
        get posts_path(format: :json), params: { tags: "md5:#{@plain.md5}", only: "md5,is_deleted,source", limit: 1 }
        assert_equal [@plain.md5], response.parsed_body.pluck("md5"), "an ordinary post is still answered"
      end

      should "not be shown a released one on the landing page" do
        [@member, User.anonymous].each do |viewer|
          assert_not_includes landing_ids(viewer), @released.id
        end
      end
    end

    # The pipeline acts on these posts and must see them: the booru's system
    # user jails as itself (the @jailed fixture, deleted by
    # Post#jail_on_banished_tags, proves that half), and the sampling bot's
    # jail sync finds a post by md5 to tag and delete it -- including a
    # half-jailed one whose delete it has to finish.
    context "the sampling bot" do
      should "find a half-jailed post by md5, to finish jailing it" do
        bot = create(:approver_user, name: "sample")
        assert_equal [@half_jailed.id], search_ids(bot, "md5:#{@half_jailed.md5}")
        get_auth post_path(@half_jailed), bot
        assert_response :success
      end

      should "not make a member who is not an editor a pipeline account" do
        assert TagBanishment.withholds_posts_from?(@member)
        assert TagBanishment.withholds_posts_from?(User.anonymous)
        assert_not TagBanishment.withholds_posts_from?(User.system)
      end
    end

    context "an admin" do
      should "get a 404 from the post page for anything jailed or banished-tagged" do
        [@jailed, @released, @half_jailed].each do |post|
          get_auth post_path(post), @admin
          assert_response 404, "post ##{post.id} (#{post.tag_string})"
        end
      end

      should "still reach an ordinary post and an ordinary deletion" do
        [@plain, @deleted].each do |post|
          get_auth post_path(post), @admin
          assert_response :success, "post ##{post.id} (#{post.tag_string})"
        end
      end

      should "get a 404 from the post's json, modulation.json and the md5 lookup" do
        [@jailed, @released].each do |post|
          get_auth post_path(post, format: :json), @admin
          assert_response 404

          get_auth post_modulation_path(post), @admin, as: :json
          assert_response 404

          get_auth posts_path, @admin, params: { md5: post.md5 }
          assert_response 404
        end
      end

      # The count of an ordinary tag is the tag's own (operator, 2026-10-17;
      # PostQuery#estimated_count); a banished NAME counts 0, as a name never
      # used does.
      should "not find them in a search, and count their banished name 0" do
        ids = search_ids(@admin, "landscape")

        assert_includes ids, @plain.id
        assert_not_includes ids, @released.id
        assert_not_includes ids, @half_jailed.id
        assert_equal Tag.find_by_name("landscape").post_count, PostSets::Post.new("landscape", 1, 20, user: @admin).post_count
        assert_equal 0, PostSets::Post.new("gore", 1, 20, user: @admin).post_count
      end

      # The sidebar's similar tags sample the search as typed (upstream
      # RelatedTagCalculator, cached across viewers by the query string), so
      # it would list what a withheld post carries. Until 2026-10-24 an
      # admin's one-tag search never reached it: -troll_jail was a term on
      # every search, so it was never a simple tag. The banished names are
      # now the row filter, which no shape check sees (PostSets::Post#similar_tags).
      should "not be shown in the sidebar what a withheld post carries" do
        released = as(@uploader) { create(:post, tag_string: "landscape gore mountain_lake", source: BOARD, uploader: @uploader, md5: SecureRandom.hex(16)) }
        as(@uploader) do
          released.update!(is_deleted: false)
          released.update!(tag_string: "landscape gore mountain_lake")
        end
        assert_not released.reload.is_deleted?, "fixture: live, still banished-tagged"

        names = PostSets::Post.new("landscape", 1, 20, user: @admin).sidebar_tags.map(&:name)

        assert_includes names, "landscape"
        assert_not_includes names, "mountain_lake"
        assert_not_includes names, JAIL
      end

      should "not find them searching status:deleted, while ordinary deletions still show" do
        ids = search_ids(@admin, "status:deleted")

        assert_includes ids, @deleted.id
        assert_not_includes ids, @jailed.id
      end

      should "not find them by naming the tag" do
        assert_empty search_ids(@admin, "gore status:any")
        assert_empty search_ids(@admin, "#{JAIL} status:any")
      end

      should "not be shown a released one on the landing page" do
        ids = landing_ids(@admin)

        assert_includes ids, @plain.id
        assert_not_includes ids, @released.id
      end

      # A list built without the implicit metatags: the uploader's strip on
      # their profile, which draws deleted uploads too (show_deleted: true).
      # The sampling bot uploaded every jailed post there is.
      should "not be drawn one in a profile's upload strip" do
        get_auth user_path(@uploader), @admin

        assert_response :success
        assert_select ".user-uploads article[data-id=?]", @plain.id.to_s, 1
        assert_select ".user-uploads article[data-id=?]", @released.id.to_s, 0
        assert_select ".user-uploads article[data-id=?]", @half_jailed.id.to_s, 0
      end

      # The booru never shows a banished name, ever (operator, relayed
      # 2026-10-12) -- not even censored behind a click in the blacklist
      # box, which every page sends to every viewer. Nothing is lost: no
      # post carrying one reaches anyone the box is drawn for.
      should "never send a banished name, nor any rule the viewer did not write" do
        [@admin, @member].each do |user|
          get_auth posts_path, user, params: { tags: "landscape" }

          assert_response :success
          assert_equal Blocklist.parse(user.blacklisted_tags).map(&:rule), rules_on_page, user.level_string
          assert_no_match(/\bgore\b/, response.body, user.level_string)
          assert_not(rules_on_page.any? { |r| r.start_with?("arthropod ") }, "the enforced conjunctions are gone")
        end
      end
    end

    # NO REVEAL (2026-10-12). An admin who once had the toggle on is
    # withheld from like every other admin: the setting is gone, and the
    # column it was stored in is never read.
    context "an admin who had reveal_banished on before it was removed" do
      setup do
        ModulationSetting.record!(@admin, nil, { "image_cap" => "fit" })
        ModulationSetting.connection.execute("UPDATE modulation_settings SET reveal_banished = TRUE WHERE user_id = #{@admin.id}")
      end

      should "still get a 404 from the post page, its json and modulation.json" do
        [@jailed, @released, @half_jailed].each do |post|
          get_auth post_path(post), @admin
          assert_response 404, "post ##{post.id} (#{post.tag_string})"

          get_auth post_modulation_path(post), @admin, as: :json
          assert_response 404
        end
      end

      should "not find them in a search or searching status:deleted" do
        assert_not_includes search_ids(@admin, "landscape"), @released.id
        assert_not_includes search_ids(@admin, "status:deleted"), @jailed.id
      end

      should "not be offered a reveal toggle, nor a banished name among the page's rules" do
        get_auth posts_path, @admin, params: { tags: "landscape" }

        assert_response :success
        assert_no_match(/Reveal banished/, response.body)
        assert_not_includes rules_on_page, "gore"
        assert_no_match(/\bgore\b/, response.body)
      end

      should "have no reveal setting to switch on" do
        login_as(@admin)
        patch modulation_settings_path, params: { reveal_banished: true }, as: :json
        assert_not response.parsed_body.key?("reveal_banished")
      end
    end

    context "everyone below admin" do
      should "get the 404 a deleted post gets for a jailed one, as before" do
        [@member, create(:moderator_user)].each do |user|
          get_auth post_path(@jailed), user
          assert_response 404
        end
      end

      # Not "as before" (2026-10-12): a released post keeps its banished tag,
      # and the banishment, not the jail, now withholds it -- from everyone
      # but the pipeline. Releasing lifts the jail; showing the post takes
      # the banished tag off it.
      should "not see a released one that still carries a banished tag" do
        get_auth post_path(@released), @member
        assert_response 404
        assert_not_includes search_ids(@member, "landscape"), @released.id
      end
    end

    should "leave the release route working for the jail panel" do
      bot = create(:approver_user, name: "sample") # the jail panel's account (fourier_jail_release_names)
      post = jailed_post(bot)

      post_auth fourier_jail_release_path, bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal true, response.parsed_body["released"]
      assert_not post.reload.is_deleted?
    end
  end

  context "The rule's switch" do
    should "be on outside the test environment and off inside it" do
      assert_equal false, Danbooru.config.banished_posts_withheld?

      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      assert_equal true, Danbooru.config.banished_posts_withheld?
    end

    should "leave an admin's view unchanged while it is off" do
      banish_tags!("gore")
      post = jailed_post(create(:approver_user))

      get_auth post_path(post), create(:admin_user)

      assert_response :success
    end
  end
end
