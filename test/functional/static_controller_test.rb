require "test_helper"

class StaticControllerTest < ActionDispatch::IntegrationTest
  context "site_map action" do
    should "work for anonymous users" do
      get site_map_path
      assert_response :success
    end

    should "work for admin users" do
      get_auth site_map_path, create(:admin_user)
      assert_response :success
    end
  end

  context "sitemap action" do
    # Each file the index lists is one page of its range, so the index pages
    # by the page a file serves (User#listing_per_page_limit): a range wider
    # than that left all but its first page unreachable, silently.
    [Artist, ForumTopic, Pool, Post, Tag, User, WikiPage].each do |klass|
      should "list #{klass.model_name.plural} files that each serve their whole range" do
        Danbooru.config.stubs(:restricted_browsing_per_page).returns(2)
        member = create(:user)
        as(member) { create_list(klass.model_name.singular.to_sym, 3) }
        relation = { Tag => Tag.nonempty, Artist => Artist.undeleted, ForumTopic => ForumTopic.undeleted, Pool => Pool.undeleted, WikiPage => WikiPage.undeleted }.fetch(klass, klass.all)

        [member, create(:restricted_user)].each do |viewer|
          login_as(viewer)
          get sitemap_path(sitemap: klass.model_name.plural), as: :xml
          assert_response :success
          locs = response.parsed_body.css("sitemap loc").map { |loc| Addressable::URI.parse(loc.text) }
          assert_not_empty(locs)
          locs.each do |uri|
            range = uri.query_values["tags"]&.delete_prefix("id:") || uri.query_values["search[id]"]
            lo, hi = range.split("..").map(&:to_i)
            assert_operator(hi - lo + 1, :<=, viewer.listing_per_page_limit, "#{viewer.level_string}: #{uri} is wider than one page")
            get uri.request_uri
            assert_response :success, uri.to_s
            served = Nokogiri::XML(response.body).remove_namespaces!.css("url > loc").size
            assert_equal(relation.where(id: lo..hi).count, served, "#{viewer.level_string}: #{uri}")
            assert_operator(served, :<=, viewer.listing_per_page_limit)
          end
        end
      end
    end

    should "serve an index for a limit of zero" do
      get sitemap_path(sitemap: "pools", limit: 0), as: :xml
      assert_response :success
    end

    should "work when the sitemap is empty" do
      get sitemap_path(sitemap: "pools"), as: :xml

      assert_response :success
    end
  end

  context "dtext_help action" do
    should "work" do
      get dtext_help_path(format: :js), xhr: true
      assert_response :success
    end
  end

  context "terms_of_service action" do
    should "work" do
      get terms_of_service_path
      assert_response :success
    end
  end

  context "the privacy policy" do
    should "be PIP2, 41chan's one policy page, not the one Danbooru shipped" do
      get privacy_policy_path
      assert_response 302
      assert_redirected_to "https://41chan.net/pip2.html"
    end

    should "be the footer's one policy link, beside the fork's source" do
      get posts_path
      assert_select "#page-footer a[href='https://41chan.net/pip2.html'][title='Policies and Pledges']", text: "PIP2", count: 1
      assert_select "#page-footer a[href*='privacy.html'], #page-footer a[href*='data-retention.html']", count: 0
      assert_select "#page-footer a[href='https://github.com/fourier-channel/chanbooru']", count: 1
      assert_select "#page-footer a[href*='danbooru/danbooru']", count: 0
    end

    should "be what the Terms placeholder points to" do
      get terms_of_service_path
      assert_select "#a-terms-of-service a[href='https://41chan.net/pip2.html']", count: 1
    end
  end

  context "2257 action" do
    should "work" do
      get usc_2257_path
      assert_response :success
    end
  end

  context "not_found action" do
    should "return the 404 page for GET requests" do
      get "/qwoiqogieqg"
      assert_response 404
    end

    should "return the 404 page for POST requests" do
      post "/qwoiqogieqg"
      assert_response 404
    end

    should "return a JSON response for a 404'd JSON request" do
      get "/qwoiqogieqg", as: :json

      assert_response 404
      assert_equal("Page not found", response.parsed_body["message"])
    end

    should "return an XML response for a 404'd XML request" do
      get "/qwoiqogieqg", as: :xml

      assert_response 404
      assert_equal("Page not found", response.parsed_body.xpath("result/message").text)
    end

    should "return a JS response for a 404'd .js request" do
      get "/qwoiqogieqg.js"

      assert_response 404
      assert_equal("", response.body)
    end

    # Fork: upstream's pool picture is gone; the 404 is the "Oh No!" page
    # (test/functional/error_page_test.rb), whose picture is its own.
    should "render the Oh No! page" do
      get "/qwoiqogieqg"

      assert_response 404
      assert_select ".oh-no .oh-no-details p", text: "Details: There is nothing at this address."
    end
  end

  context "bookmarklet action" do
    should "work" do
      get bookmarklet_path
      assert_response :success
    end
  end

  context "contact action" do
    should "work" do
      create(:owner_user)

      get contact_path
      assert_response :success
    end
  end

  context "keyboard_shortcuts action" do
    should "work" do
      get keyboard_shortcuts_path
      assert_response :success
    end
  end

  context "opensearch action" do
    should "work" do
      get opensearch_path, as: :xml
      assert_response :success
    end
  end

  context "colors action" do
    should "work" do
      get colors_path
      assert_response :success
    end
  end

  context "components action" do
    should "work" do
      get components_path
      assert_response :success
    end
  end
end
