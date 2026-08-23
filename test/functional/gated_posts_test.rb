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
      @gated = create(:post, uploader: @uploader, tag_string: "aaaa #{GATED_TAG}")
      @plain = create(:post, uploader: @uploader, tag_string: "aaaa bbbb")
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

    # The asymmetry is deliberate. A signed-in viewer below the threshold still
    # sees the listing, because for them there is something to be done about it;
    # for a signed-out visitor there is nothing to offer and nothing to disclose.
    context "for a signed-in account below the threshold" do
      should "still see the post listed, with the image withheld" do
        set = PostSets::Post.new("aaaa", 1, 100, user: @member)

        assert_includes(set.posts.map(&:id), @gated.id)
        assert_not(@gated.visible?(@member), "the image must still be withheld")
      end

      should "still reach the post page" do
        get_auth post_path(@gated), @member
        assert_response :success
      end
    end

    context "the uploader" do
      should "see their own gated post" do
        assert(@gated.visible?(@uploader))
        assert_not(@gated.hidden_from_anonymous?(@uploader))
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
      assert(@gated.hidden_from_anonymous?(nil))
    end
  end
end
