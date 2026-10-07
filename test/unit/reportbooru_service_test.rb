require "test_helper"

# Fork: #popular_posts went with /explore/posts/viewed (2026-10-07); the search
# rankings behind the popular-searches sidebar are what this service still reads.
class ReportbooruServiceTest < ActiveSupport::TestCase
  setup do
    @service = ReportbooruService.new(reportbooru_server: "http://localhost:1234")
    @date = Date.parse("2000-01-01")
  end

  context "#popular_searches" do
    should "return the day's top searches on success" do
      mock_post_search_rankings(@date, [["1girl", 100], ["original", 50]])

      assert_equal(["1girl", "original"], @service.popular_searches(@date))
    end

    should "return nothing on failure" do
      Danbooru::Http.any_instance.expects(:get).with("http://localhost:1234/post_searches/rank?date=#{@date}").returns(HTTP::Response.new(status: 500, body: "", version: "1.1", request: nil))
      Danbooru::Http.any_instance.expects(:get).with("http://localhost:1234/post_searches/rank?date=#{@date.yesterday}").returns(HTTP::Response.new(status: 500, body: "", version: "1.1", request: nil))

      assert_equal([], @service.popular_searches(@date))
    end
  end
end
