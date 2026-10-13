# frozen_string_literal: true

require "test_helper"

# The blocklist control as drawn (BlocklistComponent; operator, 2026-10-13):
# a trigger joined to the header's purge/refresh rectangle and a panel of
# pills that drops over the page. The person's own list is the only filter;
# nothing site-enforced is sent to the page.
class BlocklistComponentTest < ViewComponent::TestCase
  def init_args
    page.find("#blacklist-box", visible: :all)["x-init"]
  end

  def init_blocks
    JSON.parse(init_args[/\Ablacklist\.initialize\((\[.*\]),/m, 1])
  end

  context "for a member" do
    setup do
      @user = create(:user, blacklisted_tags: "blue_hair %locked\nrating:explicit\ninsect -pokemon")
      render_inline(BlocklistComponent.new(user: @user))
    end

    should "render one engine root with the trigger and the panel" do
      assert_css("#blacklist-box.blocklist", count: 1, visible: :all)
      assert_css("button#blocklist-trigger[data-shortcut='b'][aria-haspopup='dialog'][aria-controls='blocklist-panel']", visible: :all)
      assert_css("#blocklist-panel[role='dialog'][aria-label='Your blocklist']", visible: :all)
    end

    should "hand the engine the parsed blocks, locks included" do
      assert_equal(
        [{ "rule" => "blue_hair", "locked" => true }, { "rule" => "rating:e", "locked" => false }, { "rule" => "insect -pokemon", "locked" => false }],
        init_blocks,
      )
      assert_match(/signedIn: true/, init_args)
    end

    should "offer tag autocomplete and the text editor link" do
      assert_css("#blocklist-panel input[data-autocomplete='tag-query'][aria-label='Block a tag']", visible: :all)
      assert_css("#blocklist-panel a[href$='#user_blacklisted_tags']", text: "Edit as text", visible: :all)
    end

    should "send no enforced rules and say Blocklist, never Blacklist" do
      assert_no_css(".blacklist-enforced, .blacklist-censor", visible: :all)
      assert_no_match(/blacklist/i, page.text(:all))
      assert_match(/Blocklist/, page.text(:all))
    end
  end

  context "for a signed-out viewer" do
    setup do
      render_inline(BlocklistComponent.new(user: User.anonymous))
    end

    should "start from an empty list the browser fills, without autocomplete" do
      assert_equal([], init_blocks)
      assert_match(/signedIn: false/, init_args)
      assert_css("#blocklist-panel input[aria-label='Block a tag']", visible: :all)
      assert_no_css("#blocklist-panel input[data-autocomplete]", visible: :all)
    end

    should "say where a signed-out list is kept" do
      assert_match(/Kept in this browser until you purge it/, page.text(:all))
      assert_no_css("a[href$='#user_blacklisted_tags']", visible: :all)
    end
  end
end
