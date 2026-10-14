require "test_helper"

# Gated posts: content carrying a tag from Danbooru.config.restricted_tags.
#
# The rule is deliberately stricter than the browsing tier, and the difference
# is the point. The tier says "you may see this, but only if you already know
# where it is" -- a limit on browsing. Gating says "you may not see this kind of
# thing at all", which is a claim about the content, and a rule of that shape is
# not satisfied by withholding the image while still listing the post, its tags
# and its id.
class GatedPostsTest < ActionDispatch::IntegrationTest
  GATED_TAG = "child".freeze

  context "A gated post" do
    setup do
      @uploader = travel_to(1.month.ago) { create(:user) }
      # uploader passed explicitly: the factory's `uploader` association builds
      # its own user, so `as(...)` alone does not make @uploader the uploader --
      # which is exactly the relationship the last test in this file asserts.
      # 32-hex md5s, as a real file's: the md5: metatag reads only that shape.
      @gated = create(:post, uploader: @uploader, tag_string: "aaaa #{GATED_TAG}", md5: SecureRandom.hex(16))
      @plain = create(:post, uploader: @uploader, tag_string: "aaaa bbbb", md5: SecureRandom.hex(16))
      @member = create(:user)
      @gold = create(:gold_user)
    end

    should "be recognised as gated by its tags alone" do
      assert(@gated.gated?)
      assert_not(@plain.gated?)
    end

    # The tag list is the source of truth; this guards against someone emptying
    # it or breaking the regex and silently ungating everything.
    should "be driven by the configured tag list" do
      assert_includes(Danbooru.config.restricted_tags, GATED_TAG)
    end

    context "for a signed-out visitor" do
      should "not exist by direct link" do
        get post_path(@gated)
        assert_response :not_found
      end

      should "not exist through the API either" do
        get post_path(@gated, format: :json)
        assert_response :not_found
      end

      # The same rule by another door: an md5 lookup must not confirm what the
      # post page denies.
      should "not be findable by md5" do
        get posts_path(md5: @gated.md5)
        assert_response :not_found
      end

      should "still serve posts that are not gated" do
        get post_path(@plain)
        assert_response :success
      end

      should "be absent from search results" do
        get posts_path(tags: "aaaa", preset: "modulation")

        assert_response :success
        assert_select ".modgal-card[data-id=?]", @plain.id.to_s, 1
        assert_select ".modgal-card[data-id=?]", @gated.id.to_s, 0
      end

      # Excluded from the QUERY, not filtered from the results -- otherwise the
      # count, the paginator and "N posts" would all still betray it.
      should "be absent from the post count" do
        set = PostSets::Post.new("aaaa", 1, 100, user: User.anonymous)

        assert_not_includes(set.posts.map(&:id), @gated.id)
        assert_includes(set.posts.map(&:id), @plain.id)
        assert_equal(1, set.post_count)
      end

      should "be absent from an empty search too" do
        set = PostSets::Post.new("", 1, 100, user: User.anonymous)

        assert_not_includes(set.posts.map(&:id), @gated.id)
      end

      # Regression: the random redirect used to stringify the implicit metatags
      # into the URL, which published the entire gated tag list to the one
      # visitor it is being hidden from -- and then exceeded their tag limit on
      # the request that followed.
      should "not leak the gated tag list through a random search" do
        get posts_path(random: "true")

        assert_response :redirect
        Danbooru.config.restricted_tags.each do |tag|
          assert_no_match(/#{Regexp.escape(tag)}/, response.location, "#{tag} leaked into the redirect")
        end
      end

      should "still return only ungated posts after following a random redirect" do
        get posts_path(random: "true")
        follow_redirect!

        assert_response :success
      end

      should "be absent from the landing showcase" do
        slides = LandingShowcase.new(viewer: User.anonymous).categories.flat_map { _1[:slides] }

        assert_not_includes(slides.map { _1[:id] }, @gated.id)
        assert_operator(slides.size, :>, 0, "the showcase must not be empty, or this asserts nothing")
      end
    end

    context "for a Gold account" do
      should "be reachable by direct link" do
        get_auth post_path(@gated), @gold
        assert_response :success
      end

      should "appear in search results" do
        set = PostSets::Post.new("aaaa", 1, 100, user: @gold)

        assert_includes(set.posts.map(&:id), @gated.id)
        assert_equal(2, set.post_count)
      end
    end

    # Operator ruling 2026-10-13 (gate 1): "Gate 1 should hide sensitive posts
    # to Restricted and Member the same way it withholds the image." Below
    # Gold, a gated post does not exist -- exactly as for a signed-out
    # visitor: not its page, its JSON, an md5 lookup, search, the count, the
    # neighbours, the Modulation payload or a write. The image follows: the
    # md5 ask fourier-auth makes AS the reader finds no row.
    context "for Restricted and Member" do
      setup do
        @restricted = create(:restricted_user)
        @below_gold = { "restricted" => @restricted, "member" => @member }
      end

      should "not exist by direct link, through the API, or by md5" do
        @below_gold.each do |who, user|
          get_auth post_path(@gated), user
          assert_response 404, who
          get_auth post_path(@gated, format: :json), user
          assert_response 404, who
          get_auth posts_path(format: :json), user, params: { md5: @gated.md5 }
          assert_response 404, who
          get_auth post_path(@plain, format: :json), user
          assert_response :success, who
        end
      end

      # The ask fourier-auth's image gate makes as the reader: no row, so no
      # image.
      should "not answer the md5 ask the image gate makes as the reader" do
        @below_gold.each do |who, user|
          get_auth posts_path(format: :json), user, params: { tags: "md5:#{@gated.md5}", only: "md5,is_deleted,source" }
          assert_response :success, who
          assert_equal [], response.parsed_body, who
          get_auth posts_path(format: :json), user, params: { tags: "md5:#{@plain.md5}", only: "md5,is_deleted,source" }
          assert_equal [@plain.md5], response.parsed_body.pluck("md5"), who
        end
      end

      should "be absent from search results, the count and an empty search" do
        @below_gold.each do |who, user|
          set = PostSets::Post.new("aaaa", 1, 20, user: user)
          assert_equal [@plain.id], set.posts.map(&:id), who
          assert_equal 1, set.post_count, who
          assert_not_includes PostSets::Post.new("", 1, 20, user: user).posts.map(&:id), @gated.id, who

          get_auth posts_counts_path(format: :json), user, params: { tags: "aaaa" }
          assert_equal 1, response.parsed_body.dig("counts", "posts"), who
          get_auth posts_counts_path(format: :json), user, params: { tags: "id:#{@gated.id}" }
          assert_equal 0, response.parsed_body.dig("counts", "posts"), who
        end
      end

      should "be stepped over between neighbours" do
        first = create(:post, uploader: @uploader, tag_string: "gatednb")
        gated = create(:post, uploader: @uploader, tag_string: "gatednb #{GATED_TAG}")
        last = create(:post, uploader: @uploader, tag_string: "gatednb")
        assert_operator first.id, :<, gated.id
        assert_operator gated.id, :<, last.id

        assert_equal first.id, PostNeighbors.new(post: last, tags: "gatednb", user: @member).next_id
        assert_equal last.id, PostNeighbors.new(post: first, tags: "gatednb", user: @member).prev_id
        assert_equal gated.id, PostNeighbors.new(post: last, tags: "gatednb", user: @gold).next_id
      end

      should "not answer the Modulation payload or a write" do
        @below_gold.each do |who, user|
          get_auth post_modulation_path(@gated, format: :json), user
          assert_response 404, who
        end

        put_auth post_path(@gated, format: :json), @member, params: { post: { tag_string: "aaaa #{GATED_TAG} written" }}
        assert_response 404
        assert_not_includes @gated.reload.tag_array, "written"
      end

      # The uploader keeps its own post (the posting bots, whatever level).
      should "still be there for the account that uploaded it" do
        uploader_set = PostSets::Post.new("aaaa", 1, 100, user: @uploader)
        assert_includes uploader_set.posts.map(&:id), @gated.id
        assert_equal 2, uploader_set.post_count
        get_auth post_path(@gated, format: :json), @uploader
        assert_response :success
        get_auth posts_path(format: :json), @uploader, params: { tags: "md5:#{@gated.md5}", only: "md5" }
        assert_equal [@gated.md5], response.parsed_body.pluck("md5")
      end

      # /artists/new?artist[name]= prefills the form from the newest post
      # carrying that tag: its source, through the source's extractor, gave a
      # member the gated post's artist profile URLs (review, 2026-10-14). The
      # post is looked up as the viewer, so a hidden one lends nothing.
      context "and a new artist's defaults" do
        setup do
          as(@uploader) { create(:post, uploader: @uploader, tag_string: "gated_artist_x #{GATED_TAG}", source: "https://example.com/gated-source", md5: SecureRandom.hex(16)) }
        end

        should "not read the gated post's source below Gold" do
          Source::Extractor.expects(:find).never
          get_auth new_artist_path, @member, params: { artist: { name: "gated_artist_x" }}
          assert_response :success
        end

        should "still read it for Gold" do
          Source::Extractor.expects(:find).with("https://example.com/gated-source").returns(stub(new_artist: Artist.new))
          get_auth new_artist_path, @gold, params: { artist: { name: "gated_artist_x" }}
          assert_response :success
        end
      end

      should "still be there for Gold and Moderator" do
        [@gold, create(:moderator_user)].each do |user|
          get_auth post_path(@gated, format: :json), user
          assert_response :success, user.level_string
          assert_equal 2, PostSets::Post.new("aaaa", 1, 100, user: user).post_count, user.level_string
        end
      end
    end

    # One rule (Post#hidden_as_gated?), with upstream's name kept for the
    # image: levelblocked? answers exactly what the post's own rule does.
    context "the rule itself" do
      should "hide a gated post below Gold, from everyone but its uploader" do
        expected = {
          "nil" => [nil, true],
          "anonymous" => [User.anonymous, true],
          "restricted" => [create(:restricted_user), true],
          "member" => [@member, true],
          "gold" => [@gold, false],
          "moderator" => [create(:moderator_user), false],
          "uploader" => [@uploader, false],
        }
        expected.each do |who, (user, hidden)|
          assert_equal hidden, @gated.hidden_as_gated?(user), who
          assert_equal hidden, @gated.hidden_from?(user), who
          assert_equal @gated.hidden_as_gated?(user), @gated.levelblocked?(user), who unless user.nil?
          assert_not @plain.hidden_as_gated?(user), who
        end
      end
    end

    context "the uploader" do
      should "see their own gated post" do
        assert(@gated.visible?(@uploader))
        assert_not(@gated.hidden_as_gated?(@uploader))
      end
    end

    # The names travel even when the content cannot: readable over a shoulder,
    # screenshotted, broadcast. Hiding the posts while listing the tags that
    # describe them gives away the part that actually spreads.
    context "the tag name, for a signed-out visitor" do
      should "not appear in the tag index" do
        get tags_path(search: { name_matches: GATED_TAG })

        assert_response :success
        assert_select "a.tag-type-0", text: GATED_TAG, count: 0
        assert_no_match(/#{GATED_TAG}/, css_select("#c-tags").to_s)
      end

      should "not be suggested by autocomplete" do
        results = AutocompleteService.new(GATED_TAG[0, 3], :tag_query, current_user: User.anonymous).autocomplete_results

        assert_not_includes(results.map { _1[:value] }, GATED_TAG)
      end

      # An alias pointing at a gated tag discloses it just as plainly as naming
      # it, so the antecedent is checked too.
      should "not be reachable through an alias in autocomplete" do
        create(:tag_alias, antecedent_name: "kiddo", consequent_name: GATED_TAG)
        results = AutocompleteService.new("kid", :tag_query, current_user: User.anonymous).autocomplete_results

        assert_not_includes(results.map { _1[:value] }, GATED_TAG)
        assert_not_includes(results.map { _1[:antecedent] }, GATED_TAG)
      end

      should "leave ordinary tags alone" do
        get tags_path(search: { name_matches: "aaaa" })

        assert_response :success
        results = AutocompleteService.new("aaa", :tag_query, current_user: User.anonymous).autocomplete_results
        assert_includes(results.map { _1[:value] }, "aaaa")
      end
    end

    # Operator, 2026-10-14: gated tag names follow the post. Below Gold the
    # posts do not exist (gate 1), so their names are withheld exactly as
    # from a signed-out visitor: the tag index, autocomplete, a tag's own
    # page and the related tags.
    context "the tag name, for Restricted and Member" do
      setup do
        @viewers = { "restricted" => create(:restricted_user), "member" => @member }
      end

      should "not appear in the tag index" do
        @viewers.each do |who, viewer|
          get_auth tags_path(search: { name_matches: GATED_TAG }), viewer
          assert_response 200, who
          assert_no_match(/#{GATED_TAG}/, css_select("#c-tags").to_s, who)

          get_auth tags_path(format: :json, search: { name_matches: GATED_TAG }), viewer
          assert_equal [], response.parsed_body.pluck("name"), who
        end
      end

      should "not open its own page" do
        tag = Tag.find_by!(name: GATED_TAG)
        @viewers.each do |who, viewer|
          get_auth tag_path(tag, format: :json), viewer
          assert_response 404, who
        end
      end

      should "not be suggested by autocomplete, by name or through an alias" do
        create(:tag_alias, antecedent_name: "kiddo", consequent_name: GATED_TAG)
        @viewers.each do |who, viewer|
          named = AutocompleteService.new(GATED_TAG[0, 3], :tag_query, current_user: viewer).autocomplete_results
          aliased = AutocompleteService.new("kid", :tag_query, current_user: viewer).autocomplete_results

          assert_not_includes(named.pluck(:value), GATED_TAG, who)
          assert_not_includes(aliased.pluck(:value), GATED_TAG, who)
          assert_not_includes(aliased.pluck(:antecedent), GATED_TAG, who)
        end
      end

      should "be in the list of names withheld from them" do
        @viewers.each do |who, viewer|
          assert_includes Tag.hidden_names_for(viewer), GATED_TAG, who
          assert_not_includes Tag.visible_to(viewer).pluck(:name), GATED_TAG, who
        end
        assert_not_includes Tag.hidden_names_for(@gold), GATED_TAG
      end

      should "leave ordinary tags alone" do
        @viewers.each do |who, viewer|
          results = AutocompleteService.new("aaa", :tag_query, current_user: viewer).autocomplete_results
          assert_includes(results.pluck(:value), "aaaa", who)
        end
      end

      # The post's own tag list is the post, not a listing: a viewer who may
      # open the post (here its below-Gold uploader) still reads its tags.
      should "still be listed on a gated post the viewer may open" do
        get_auth post_path(@gated), @uploader
        assert_response 200
        assert_select "[data-tag-name=?]", GATED_TAG
      end

      # ... but not in the search sidebar beside it, which lists the names
      # on the page's posts (review, 2026-10-14): the uploader's own gated
      # post is in their results, its gated name is not a listing's.
      should "not be listed in the search sidebar of the uploader's own gated post" do
        uploader = create(:user)
        as(uploader) { create(:post, uploader: uploader, tag_string: "ownside #{GATED_TAG}") }
        sidebar = PostSets::Post.new("ownside", 1, 20, user: uploader).sidebar_tags.map(&:name)
        assert_includes sidebar, "ownside"
        assert_not_includes sidebar, GATED_TAG
        get_auth posts_path, uploader, params: { tags: "ownside" }
        assert_response 200
        assert_select "a.search-tag", text: "ownside"
        assert_select "a.search-tag", text: GATED_TAG, count: 0
        assert_includes PostSets::Post.new("ownside", 1, 20, user: @gold).sidebar_tags.map(&:name), GATED_TAG
      end
    end

    context "the tag name, for a Gold account" do
      should "still appear in the tag index" do
        get_auth tags_path(search: { name_matches: GATED_TAG }), @gold

        assert_response :success
        assert_match(/#{GATED_TAG}/, response.body)
      end

      should "still be suggested by autocomplete" do
        results = AutocompleteService.new(GATED_TAG[0, 3], :tag_query, current_user: @gold).autocomplete_results

        assert_includes(results.map { _1[:value] }, GATED_TAG)
      end
    end

    should "treat an unknown viewer as anonymous" do
      # A rule about withholding content has to fail towards withholding.
      assert(@gated.hidden_as_gated?(nil))
    end
  end
end
