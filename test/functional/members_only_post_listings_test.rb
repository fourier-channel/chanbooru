# frozen_string_literal: true

require "test_helper"

# Every listing that names posts is for members only (operator ruling
# 2026-10-07: "An anonymous viewer is not supposed to be paging through all of
# the content 20 posts at a time."). The rule is MembersOnly.post_listing!,
# asked from ApplicationRecord.paginated_search for every model that
# names_posts?, and by hand at the doors that list posts without it.
#
# The switch is off under test (the fork restriction pattern), so this file
# stubs it on and is the place the rule is proven: a signed-out visitor gets
# the hidden-post 404 at every door, html and json; a member's answer is the
# one they had before.
class MembersOnlyPostListingsTest < ActionDispatch::IntegrationTest
  # The doors the ruling named, and every other one found by reading the
  # routes for listings that name posts. A lambda, because a path can need a
  # record made in setup.
  DOORS = {
    "popular" => -> { popular_explore_posts_path },
    "popular, another day at a bigger page" => -> { popular_explore_posts_path(date: "2026-01-01", scale: "month", page: 2, limit: 100) },
    "artist commentaries" => -> { artist_commentaries_path(page: 2) },
    "artist commentary versions" => -> { artist_commentary_versions_path },
    "post approvals" => -> { post_approvals_path(page: 2) },
    "post disapprovals" => -> { post_disapprovals_path },
    "post events" => -> { post_events_path },
    "a post's events" => -> { post_events_path(post_id: @post.id) },
    "post votes" => -> { post_votes_path },
    "post appeals" => -> { post_appeals_path },
    "post flags" => -> { post_flags_path },
    "post replacements" => -> { post_replacements_path },
    "post versions" => -> { post_versions_path },
    "favorites" => -> { favorites_path },
    "a post's favorites" => -> { post_favorites_path(@post) },
    "favorite groups" => -> { favorite_groups_path },
    "a favorite group's posts" => -> { favorite_group_path(@favgroup) },
    "uploads" => -> { uploads_path },
    "upload media assets" => -> { upload_media_assets_path },
    "media assets" => -> { media_assets_path },
    "ai tags" => -> { ai_tags_path },
    "media metadata" => -> { media_metadata_path },
    "comments" => -> { comments_path },
    "comment votes" => -> { comment_votes_path },
    "notes" => -> { notes_path },
    "note versions" => -> { note_versions_path },
    "pools" => -> { pools_path },
    "the pool gallery" => -> { gallery_pools_path },
    "a pool's posts" => -> { pool_path(@pool) },
    "pool versions" => -> { pool_versions_path },
    "mod actions" => -> { mod_actions_path },
    "user actions" => -> { user_actions_path },
    "reactions" => -> { reactions_path },
    "dtext links" => -> { dtext_links_path },
    "moderation reports" => -> { moderation_reports_path },
    "similar image search" => -> { iqdb_queries_path(post_id: @post.id) },
    "recommended posts" => -> { recommended_posts_path },
    "the moderator dashboard" => -> { moderator_dashboard_path },
  }.freeze

  # The doors the operator measured open on production, where a plain member
  # must still be let through (the others keep whatever upstream's policy
  # gives a member, compared below).
  MEMBER_200 = [
    "popular", "artist commentaries", "post approvals", "favorites", "post events",
    "post votes", "post appeals", "post flags", "post replacements", "favorite groups",
    "uploads", "pools", "the pool gallery", "a pool's posts", "a favorite group's posts",
  ].freeze

  def door(name) = instance_exec(&DOORS.fetch(name))

  def with_format(path, format)
    uri = URI.parse(path)
    uri.path = "#{uri.path}.#{format}"
    uri.to_s
  end

  def status_of(path, user)
    user ? get_auth(path, user) : get(path)
    response.status
  end

  context "With the members-only rule on" do
    setup do
      Danbooru.config.stubs(:post_listings_members_only?).returns(true)
      @member = create(:user, created_at: 1.month.ago)
      @post = create(:post)
      @pool = as(@member) { create(:pool, post_ids: [@post.id]) }
      @favgroup = as(@member) { create(:favorite_group, creator: @member, post_ids: [@post.id]) }
      as(@member) { create(:artist_commentary, post: @post) }
    end

    DOORS.each_key do |name|
      should "refuse a signed-out visitor #{name}, html and json, with the hidden-post 404" do
        path = door(name)
        get path
        assert_response 404, "#{name}: #{path}"
        get with_format(path, "json")
        assert_response 404, "#{name}: #{path} as json"
      end
    end

    should "let a member through every door the operator measured open" do
      MEMBER_200.each do |name|
        assert_equal(200, status_of(door(name), @member), "#{name} as a member")
        assert_equal(200, status_of(with_format(door(name), "json"), @member), "#{name} as a member, json")
      end
    end

    should "give a member at every door exactly what they got with the rule off" do
      on = DOORS.keys.index_with { |name| status_of(with_format(door(name), "json"), @member) }
      Danbooru.config.stubs(:post_listings_members_only?).returns(false)
      off = DOORS.keys.index_with { |name| status_of(with_format(door(name), "json"), @member) }
      assert_equal(off, on)
    end

    should "cover a listing of any model that names posts without that listing knowing" do
      Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/models"))
      models = ApplicationRecord.descendants.select { |m| !m.abstract_class? && m.names_posts? }
      assert_includes(models, ArtistCommentary)

      checked = models.filter_map do |model|
        helper = "#{model.model_name.route_key}_path"
        next unless respond_to?(helper)

        get send(helper, format: :json)
        assert_response 404, "#{model.name} via #{helper}"
        model
      end
      assert_operator(checked.size, :>=, 20, "the derivation found too few listings to trust: #{checked.map(&:name)}")
    end

    should "leave the post index, a post's own page and the landing page alone" do
      get posts_path
      assert_response :success
      get post_path(@post)
      assert_response :success
      get root_path
      assert_response :success
    end
  end

  context "With the rule as the inherited suite runs it (off under test)" do
    should "list for a signed-out visitor as upstream does" do
      create(:post)
      get popular_explore_posts_path
      assert_response :success
      get artist_commentaries_path
      assert_response :success
    end
  end

  context "The Reportbooru explore pages" do
    should "be gone: viewed, searches and missed searches" do
      member = create(:user)
      %w[/explore/posts/viewed /explore/posts/searches /explore/posts/missed_searches /explore/posts/viewed.json].each do |path|
        get_auth path, member
        assert_response 404, path
      end
    end
  end
end
