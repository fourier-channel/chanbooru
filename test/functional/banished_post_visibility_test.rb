# frozen_string_literal: true

require "test_helper"

# A post carrying the jail tag or a banished tag is withheld from an admin
# whose reveal_banished is off (operator, 2026-09-24): such a post "is
# supposed to immediately disappear from the booru view surface for all but
# an admin with the setting explicitly ON to view it."
#
# Before this, admins saw jailed posts whatever the toggle said -- they can
# see deleted posts, and nothing else asked -- while an admin WITH the toggle
# on still had banished-tagged posts hard-hidden by the enforced blacklist.
# The toggle meant "show me the names" and nothing about the pictures.
#
# The rule is off under test (Danbooru.config.banished_posts_need_reveal?,
# the fork restriction pattern) and asserted here with it stubbed on, in the
# production shape: deleted posts visible from ADMIN up, as in production.
class BanishedPostVisibilityTest < ActionDispatch::IntegrationTest
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

  def reveal!(admin)
    ModulationSetting.record!(admin, nil, { "reveal_banished" => "true" })
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

  # The enforced rules the blacklist box is initialised with on this page.
  def enforced_rules_on_page
    init = css_select("#blacklist-box").first&.attribute("x-init")&.value.to_s
    JSON.parse(init[/blacklist\.initialize\(.*?,\s*(\[.*\])\)\z/m, 1] || "[]")
  end

  context "With the rule on" do
    setup do
      Danbooru.config.stubs(:banished_posts_need_reveal?).returns(true)
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)

      # An approver, as the sampling bot is: below contributor, a deleted
      # upload counts against the upload limit, and every jailing is one.
      @uploader = create(:approver_user)
      @jailed = jailed_post(@uploader)
      @released = released_post(@uploader)
      # troll_jail on a live post: a jailing whose delete half never landed.
      @half_jailed = as(@uploader) { create(:post, tag_string: "landscape #{JAIL}", source: BOARD, uploader: @uploader) }
      @plain = as(@uploader) { create(:post, tag_string: "landscape", source: BOARD, uploader: @uploader) }
      @deleted = as(@uploader) { create(:post, tag_string: "landscape", source: BOARD, uploader: @uploader) }
      @deleted.update!(is_deleted: true)

      @admin_off = create(:admin_user)
      @admin_on = create(:admin_user)
      reveal!(@admin_on)
      @member = create(:user)

      assert @jailed.is_deleted? && @jailed.has_tag?(JAIL), "fixture: the booru jails a post created with gore"
      assert_not @released.is_deleted?, "fixture: the released post is live"
    end

    context "an admin with reveal_banished OFF" do
      should "get a 404 from the post page for anything jailed or banished-tagged" do
        [@jailed, @released, @half_jailed].each do |post|
          get_auth post_path(post), @admin_off
          assert_response 404, "post ##{post.id} (#{post.tag_string})"
        end
      end

      should "still reach an ordinary post and an ordinary deletion" do
        [@plain, @deleted].each do |post|
          get_auth post_path(post), @admin_off
          assert_response :success, "post ##{post.id} (#{post.tag_string})"
        end
      end

      should "get a 404 from the post's json, modulation.json and the md5 lookup" do
        [@jailed, @released].each do |post|
          get_auth post_path(post, format: :json), @admin_off
          assert_response 404

          get_auth post_modulation_path(post), @admin_off, as: :json
          assert_response 404

          get_auth posts_path, @admin_off, params: { md5: post.md5 }
          assert_response 404
        end
      end

      should "not find them in a search, or in its count" do
        ids = search_ids(@admin_off, "landscape")

        assert_includes ids, @plain.id
        assert_not_includes ids, @released.id
        assert_not_includes ids, @half_jailed.id
        assert_equal 2, PostSets::Post.new("landscape", 1, 20, user: @admin_off).post_count, "plain and the ordinary deletion"
      end

      should "not find them searching status:deleted, while ordinary deletions still show" do
        ids = search_ids(@admin_off, "status:deleted")

        assert_includes ids, @deleted.id
        assert_not_includes ids, @jailed.id
      end

      should "not find them by naming the tag" do
        assert_empty search_ids(@admin_off, "gore status:any")
        assert_empty search_ids(@admin_off, "#{JAIL} status:any")
      end

      should "not be shown a released one on the landing page" do
        ids = landing_ids(@admin_off)

        assert_includes ids, @plain.id
        assert_not_includes ids, @released.id
      end

      # A list built without the implicit metatags: the uploader's strip on
      # their profile, which draws deleted uploads too (show_deleted: true).
      # The sampling bot uploaded every jailed post there is.
      should "not be drawn one in a profile's upload strip" do
        get_auth user_path(@uploader), @admin_off

        assert_response :success
        assert_select ".user-uploads article[data-id=?]", @plain.id.to_s, 1
        assert_select ".user-uploads article[data-id=?]", @released.id.to_s, 0
        assert_select ".user-uploads article[data-id=?]", @half_jailed.id.to_s, 0
      end

      should "keep the banished names among the enforced blacklist rules" do
        get_auth posts_path, @admin_off, params: { tags: "landscape" }

        assert_response :success
        assert_includes enforced_rules_on_page, "gore"
      end
    end

    context "an admin with reveal_banished ON" do
      should "reach the post page, its json and modulation.json" do
        [@jailed, @released, @half_jailed].each do |post|
          get_auth post_path(post), @admin_on
          assert_response :success, "post ##{post.id} (#{post.tag_string})"

          get_auth post_modulation_path(post), @admin_on, as: :json
          assert_response :success
        end
      end

      should "find them in a search and searching status:deleted" do
        assert_includes search_ids(@admin_on, "landscape"), @released.id
        assert_includes search_ids(@admin_on, "status:deleted"), @jailed.id
        assert_equal 5, PostSets::Post.new("landscape status:any", 1, 20, user: @admin_on).post_count
      end

      should "be shown a released one on the landing page" do
        assert_includes landing_ids(@admin_on), @released.id
      end

      should "be drawn them in a profile's upload strip" do
        get_auth user_path(@uploader), @admin_on

        assert_response :success
        assert_select ".user-uploads article[data-id=?]", @released.id.to_s, 1
        assert_select ".user-uploads article[data-id=?]", @half_jailed.id.to_s, 1
      end

      should "not have them hard-hidden by the enforced blacklist" do
        get_auth posts_path, @admin_on, params: { tags: "landscape" }

        assert_response :success
        rules = enforced_rules_on_page
        assert_not_empty rules, "the enforced rules are still rendered"
        assert_empty rules & Danbooru.config.banished_tags
        # the conjunction rules are not banishment, and stay
        assert(rules.any? { |r| r.start_with?("arthropod ") })
      end

      # How a jailed post is released by hand: with reveal on, from the
      # post page's moderation pill. (With it off the page is a 404, and
      # release goes through fourier-sampling's curation surface, which
      # calls POST /fourier_jail/release -- asserted below.)
      should "be able to release a jailed post from the post page pill" do
        login_as(@admin_on)
        get post_path(@jailed)
        assert_response :success

        patch modulation_moderation_path(@jailed), params: { jail: false }, as: :json
        assert_response :success
        patch modulation_moderation_path(@jailed), params: { deleted: false }, as: :json
        assert_response :success

        @jailed.reload
        assert_not @jailed.is_deleted?
        assert_not @jailed.has_tag?(JAIL)
      end
    end

    context "everyone below admin" do
      should "get the 404 a deleted post gets for a jailed one, as before" do
        [@member, create(:moderator_user)].each do |user|
          get_auth post_path(@jailed), user
          assert_response 404
        end
      end

      should "see a released one exactly as before" do
        get_auth post_path(@released), @member
        assert_response :success
        assert_includes search_ids(@member, "landscape"), @released.id
      end
    end

    should "leave the release route working whatever any admin's toggle says" do
      bot = create(:approver_user)
      post = jailed_post(bot)

      post_auth fourier_jail_release_path, bot, params: { md5: post.md5 }

      assert_response :success
      assert_equal true, response.parsed_body["released"]
      assert_not post.reload.is_deleted?
    end
  end

  context "The rule's switch" do
    should "be on outside the test environment and off inside it" do
      assert_equal false, Danbooru.config.banished_posts_need_reveal?

      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      assert_equal true, Danbooru.config.banished_posts_need_reveal?
    end

    should "leave an admin's view unchanged while it is off" do
      post = jailed_post(create(:approver_user))

      get_auth post_path(post), create(:admin_user)

      assert_response :success
    end
  end
end
