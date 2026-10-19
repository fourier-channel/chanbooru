# frozen_string_literal: true

require "test_helper"

# THE BROWSING TIER, ASKED OF THE USER AND ENFORCED AT THE CHOKEPOINTS
# (ACCOUNT_LIMITS.md 5.2). Operator, 2026-10-17: "If an account has a certain
# limit on one surface it should have that limit across all surfaces." The
# question is three User methods derived from level; the answer is enforced by
# PaginationExtension#paginate for every list and by the walkers for "the next
# post". The table walk (browsing_tier_surfaces_test.rb) proves the surfaces.
class BrowsingTierTest < ActiveSupport::TestCase
  CAP = 2

  setup do
    Danbooru.config.stubs(:restricted_browsing_per_page).returns(CAP)
    @restricted = create(:restricted_user)
    @member = create(:user)
    @gold = create(:gold_user)
    @admin = create(:admin_user)
    @posts = create_list(:post, 5)
    CurrentUser.user = @member
  end

  teardown do
    CurrentUser.user = nil
  end

  context "User" do
    should "answer the three questions from its level" do
      [User.anonymous, @restricted].each do |user|
        assert_not(user.can_browse_freely?, user.level_string)
        assert_equal(1, user.listing_page_limit, user.level_string)
        assert_equal(CAP, user.listing_per_page_limit, user.level_string)
      end
      [@member, @gold, @admin].each do |user|
        assert(user.can_browse_freely?, user.level_string)
        assert_equal(user.page_limit, user.listing_page_limit, user.level_string)
        assert_equal(User::MAX_PER_PAGE, user.listing_per_page_limit, user.level_string)
      end
      assert_equal(5000, @gold.listing_page_limit)
    end

    # The tracked defaults (ACCOUNT_LIMITS.md 2.7), read from the base class:
    # the untracked local config overrides them in this checkout, so nothing
    # else here would notice a clean checkout running with the tier open.
    should "ship tracked defaults that leave a new account below full browsing" do
      defaults = Danbooru::Configuration.new
      assert_equal(User::Levels::MEMBER, defaults.full_browsing_level)
      assert_equal(20, defaults.restricted_browsing_per_page)
      assert_equal(User::Levels::RESTRICTED, defaults.default_user_level)
    end

    should "move all of them, and the tag limit, with the threshold" do
      Danbooru.config.stubs(:full_browsing_level).returns(User::Levels::GOLD)

      assert_not(@member.can_browse_freely?)
      assert_equal(1, @member.listing_page_limit)
      assert_equal(CAP, @member.listing_per_page_limit)
      assert_equal(2, @member.tag_query_limit)
      assert(@gold.can_browse_freely?)
      assert_equal(Float::INFINITY, @gold.tag_query_limit)
    end
  end

  context "paginate for a viewer below full browsing" do
    should "refuse page 2 and every cursor" do
      ["2", "b#{@posts.last.id}", "a0"].each do |page|
        assert_raises(PaginationExtension::BrowsingCapError, page) { Post.order(id: :desc).paginate(page, viewer: @restricted) }
      end
    end

    should "clamp the page size, and draw no further pages" do
      posts = Post.order(id: :desc).paginate(1, limit: 1000, viewer: @restricted)

      assert_equal(CAP, posts.records_per_page)
      assert_equal(1, posts.paginator_page_limit)
      assert_nil(posts.next_page)
    end

    should "list rows in the order a full account sees them" do
      capped = Post.order(id: :desc).paginate(1, limit: CAP, viewer: @restricted).map(&:id)
      full = Post.order(id: :desc).paginate(1, limit: CAP, viewer: @member).map(&:id)

      assert_equal(full, capped)
      assert_equal(@posts.map(&:id).sort.reverse.first(CAP), capped)
    end

    should "ask the viewer it is given, not CurrentUser" do
      CurrentUser.user = @member
      assert_raises(PaginationExtension::BrowsingCapError) { Post.paginate(2, viewer: @restricted) }
      assert_equal(CAP, Post.paginate(1, limit: 100, viewer: @restricted).records_per_page)
    end

    should "bound a list of tags exactly as a list of posts" do
      assert_raises(PaginationExtension::BrowsingCapError) { Tag.paginate(2, viewer: @restricted) }
      assert_equal(CAP, Tag.paginate(1, limit: 1000, viewer: @restricted).records_per_page)
    end

    should "let the hero band through by name, and nothing by a name it does not know" do
      band = Post.order(id: :desc).paginate(1, limit: 80, viewer: User.anonymous, tier_exempt: :hero_band)
      assert_equal(80, band.records_per_page)

      error = assert_raises(ArgumentError) { Post.paginate(1, viewer: User.anonymous, tier_exempt: :sidebar) }
      assert_match(/sidebar/, error.message)
    end

    should "refuse a seek that names a place, and serve one from the head" do
      place = PostNeighbors::Seek.parse("id_desc", @posts.last.id.to_s, direction: :forward)
      assert_raises(PaginationExtension::BrowsingCapError) { Post.paginate(nil, seek: place, viewer: @restricted) }
      before = PostNeighbors::Seek.parse("id_desc", @posts.last.id.to_s, direction: :backward)
      assert_raises(PaginationExtension::BrowsingCapError) { Post.paginate(nil, seek: before, viewer: @restricted) }
      position = PostNeighbors::Seek.parse("comment_bumped", "@20", direction: :forward)
      assert_raises(PaginationExtension::BrowsingCapError) { Post.paginate(nil, seek: position, viewer: @restricted) }

      head = Post.paginate(nil, limit: 100, seek: PostNeighbors::Seek.head("id_desc"), viewer: @restricted)
      assert_equal(CAP, head.to_a.size)
    end

    should "name its fix" do
      error = assert_raises(PaginationExtension::BrowsingCapError) { Post.paginate(2, viewer: @restricted) }
      assert_match(/one page/, error.message)
      assert_match(/#{CAP} at most/, error.message)
      assert_match(/Fix:/, error.message)
    end

    should "refuse a paginate with no viewer at all, by name" do
      CurrentUser.user = nil
      error = assert_raises(ArgumentError) { Post.paginate(1) }
      assert_match(/viewer/, error.message)
    end
  end

  # Every model, the ones added later included: the tier needs no list of
  # models to keep in step with (operator, 2026-10-18: every listing).
  context "every model" do
    should "be bounded below full browsing" do
      Rails.application.eager_load!
      models = ApplicationRecord.descendants.reject(&:abstract_class?)
      assert_operator(models.size, :>, 50, "fixture: the models loaded")

      unbounded = models.reject do |model|
        model.all.paginate(2, viewer: @restricted)
        false
      rescue PaginationExtension::BrowsingCapError
        true
      end
      assert_empty(unbounded.map(&:name))
    end
  end

  context "the walkers" do
    setup do
      @pool = create(:pool, post_ids: @posts.map(&:id))
    end

    should "refuse the next post to a viewer below full browsing" do
      assert_raises(PaginationExtension::BrowsingCapError) { PostNeighbors.new(post: @posts[2], user: @restricted).run(:next) }
      assert_raises(PaginationExtension::BrowsingCapError) { PostNeighbors.new(post: @posts[2], user: User.anonymous).next_id }
      assert_raises(PaginationExtension::BrowsingCapError) { @pool.next_post_id(@posts[2].id, @restricted) }
      assert_raises(PaginationExtension::BrowsingCapError) { @pool.previous_post_id(@posts[2].id, @restricted) }
      assert_raises(PaginationExtension::BrowsingCapError) { RandomTrail.new(@restricted, nil, "").neighbours_for(@posts[2]) { nil } }
    end

    should "walk for a full account" do
      assert_equal(@posts[1].id, PostNeighbors.new(post: @posts[2], user: @member).next_id)
      assert_equal(@posts[3].id, @pool.next_post_id(@posts[2].id, @member))
      assert_equal(@posts[1].id, @pool.previous_post_id(@posts[2].id, @member))
      assert_nil(@pool.previous_post_id(@posts[0].id, @member))
      assert_nil(@pool.next_post_id(@posts[4].id, @member))
    end
  end

  context "posts inside a response" do
    setup do
      @pool = create(:pool, post_ids: @posts.map(&:id))
      @favgroup = create(:favorite_group, creator: @member, post_ids: @posts.map(&:id))
      @parent = create(:post)
      @children = create_list(:post, 4, parent: @parent)
    end

    should "cut a record's id array to the first page below full browsing" do
      CurrentUser.user = @restricted
      assert_equal(@posts.map(&:id).first(CAP), @pool.reload.as_json["post_ids"])
      assert_equal(@posts.map(&:id).first(CAP), @favgroup.reload.as_json["post_ids"])
      version = PoolVersion.where(pool_id: @pool.id).sole
      assert_equal(@posts.map(&:id).first(CAP), version.as_json["post_ids"])

      CurrentUser.user = @member
      assert_equal(@posts.map(&:id), @pool.reload.as_json["post_ids"])
      assert_equal(@posts.map(&:id), version.as_json["post_ids"])
    end

    # The creator's own list is the ids they wrote, and the edit form shows
    # them whole: cut, a read-modify-write of the JSON dropped the rest.
    should "give a favorite group's own creator its whole list" do
      mine = as(@restricted) { create(:favorite_group, creator: @restricted, post_ids: @posts.map(&:id)) }
      CurrentUser.user = @restricted
      assert_equal(@posts.map(&:id), mine.reload.as_json["post_ids"])
      assert_equal(@posts.map(&:id).first(CAP), @favgroup.reload.as_json["post_ids"])
    end

    # The pool history's HTML diff names the same ids as its JSON arrays.
    should "cut a version's diff to the first page, as its arrays are" do
      version = PoolVersion.where(pool_id: @pool.id).sole
      assert_equal(@posts.map(&:id).first(CAP), version.shown_ids(version.post_ids, @restricted))
      assert_equal(@posts.map(&:id), version.shown_ids(version.post_ids, @member))
    end

    should "cut a nested has-many of posts, and a family, to the first page" do
      CurrentUser.user = @restricted
      assert_equal(CAP, @parent.reload.as_json(include: { children: { only: [:id] }})["children"].size)
      assert_equal(CAP, @parent.reload.relatives_shown_to(@restricted)[:children].size)
      # A parent link is one hop within a family, not a walk: it stays.
      assert_equal(@parent, @children.first.reload.relatives_shown_to(@restricted)[:parent])
      assert_equal(CAP, @children.first.relatives_shown_to(@restricted)[:siblings].size)

      CurrentUser.user = @member
      assert_equal(4, @parent.reload.as_json(include: { children: { only: [:id] }})["children"].size)
      assert_equal(4, @parent.reload.relatives_shown_to(@member)[:children].size)
    end

    # Any nested list, not only one of posts: a tag's aliases, a wiki page's
    # links (and the posts they embed).
    should "cut a nested has-many of anything to the first page" do
      tag = create(:tag, name: "tiernested", post_count: 1)
      as(@admin) { Array.new(5) { |i| create(:tag_alias, antecedent_name: "tiernested_a#{i}", consequent_name: "tiernested") } }

      CurrentUser.user = @restricted
      assert_equal(CAP, tag.reload.as_json(include: { consequent_aliases: { only: [:id] }})["consequent_aliases"].size)
      CurrentUser.user = @member
      assert_equal(5, tag.reload.as_json(include: { consequent_aliases: { only: [:id] }})["consequent_aliases"].size)
    end

    should "ask IQDB for no more than the viewer's page, and keep no more" do
      mock_iqdb_matches(@posts.map { |p| { post_id: p.id, score: 95.0 } })
      HTTP::Client.any_instance.expects(:post).with { |_url, options| options.dig(:params, :limit) == CAP }.returns(
        HTTP::Response.new(status: 200, body: @posts.map { |p| { post_id: p.id, score: 95.0 } }.to_json, headers: { "Content-Type": "application/json" }, version: "1.1", request: nil),
      )
      matches = IqdbClient.new.search(hash: "abc", limit: 1000, user: @restricted)
      assert_equal(CAP, matches.size)
    end

    should "render a preview's embeds up to the viewer's page" do
      body = @posts.map { |p| "!post ##{p.id}" }.join("\n\n")
      dtext = DText.new(body, media_embeds: true)
      capped = Nokogiri::HTML5.fragment(dtext.format_text(current_user: @restricted))
      assert_equal(@posts.size, capped.css("article.dtext-media-embed").size)
      assert_operator(capped.css("article.dtext-media-embed .media-embed-image img").size, :<=, CAP)
      assert_match(/full account/, capped.to_html)

      full = Nokogiri::HTML5.fragment(dtext.format_text(current_user: @member))
      assert_equal(@posts.size, full.css("article.dtext-media-embed .media-embed-image img").size)
    end

    # [ta:N], [ti:N] and [bur:N] embeds draw each record: a list too.
    should "render a preview's tag request embeds up to the viewer's page" do
      aliases = as(@admin) { Array.new(5) { |i| create(:tag_alias, antecedent_name: "tierembed_a#{i}", consequent_name: "tierembed_c#{i}") } }
      dtext = DText.new(aliases.map { |a| "[ta:#{a.id}]" }.join("\n\n"))
      drawn = ->(html) { aliases.count { |a| Nokogiri::HTML5.fragment(html).css("a[href$='/wiki_pages/#{a.antecedent_name}']").any? } }

      capped = dtext.format_text(current_user: @restricted)
      assert_equal(CAP, drawn.call(capped))
      assert_match(/full account/, capped)
      assert_equal(5, drawn.call(dtext.format_text(current_user: @member)))
    end
  end
end
