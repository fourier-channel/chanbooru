require "application_system_test_case"

# The blocklist engine in a real browser. Needs a browser in the test
# container (vesper's has none, so this does not run there).
class BlacklistTest < ApplicationSystemTestCase
  context "The blocklist" do
    should "hide a blocked post on the post index" do
      user = create(:user, created_at: 1.month.ago, blacklisted_tags: "spoilers")
      create(:post, tag_string: "spoilers")
      create(:post, tag_string: "landscape")

      signin(user)
      visit posts_path
      assert_selector ".post-preview.blacklisted-hidden", visible: :hidden, count: 1
      assert_selector ".post-preview:not(.blacklisted-hidden)", count: 1
    end
  end
end
