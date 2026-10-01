require "test_helper"

# The creator lamps' re-read (/modulation/creator_activity). The landing
# carousel asks about every creator its rows credit, which can be far more than
# the post page's handful.
class CreatorActivityTest < ActionDispatch::IntegrationTest
  context "the creator activity endpoint" do
    should "answer for as many names as a landing page carries, not only twenty" do
      create(:artist_tag, name: "late_artist")
      as(create(:user)) { create(:post, tag_string: "late_artist") }
      names = (1..30).map { |i| "artist_#{i}" } + ["late_artist"]

      get modulation_creator_activity_path(tags: names.join(","), format: :json)

      assert_response :success
      assert_equal ["late_artist"], response.parsed_body["active"]
    end
  end
end
