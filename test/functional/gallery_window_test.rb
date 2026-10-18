# frozen_string_literal: true

require "test_helper"

# The Modulation gallery window (GALLERY_WINDOW.md section 2): the page draws
# WINDOW_CHUNK cards and shows WINDOW_SLOTS of them, and the browser fetches
# more of the same search as chunks -- the same route, variant=window, the
# same card renderer -- from a cursor minted from the cards it drew.
#
# preset: "modulation" on every request: the test environment defaults to
# the historical preset (Danbooru.config.default_experience_preset).
class GalleryWindowTest < ActionDispatch::IntegrationTest
  SLOTS = PostSets::Post::WINDOW_SLOTS
  CHUNK = PostSets::Post::WINDOW_CHUNK

  def page_html(user, **params)
    get_auth posts_path, user, params: { preset: "modulation", **params }
    response.body
  end

  def cards
    css_select(".modgal-grid .modgal-card[data-id]")
  end

  # A card's markup, without the window's on/off mark.
  def card_markup(id)
    card = css_select(".modgal-card[data-id='#{id}']").first
    card.to_html.sub(/ is-off(?=")/, "")
  end

  context "The gallery window" do
    setup do
      @member = create(:user)
      @posts = as(@member) { create_list(:post, CHUNK + 2, tag_string: "gwtest") }
      @ids = @posts.map(&:id).sort.reverse
    end

    should "draw a chunk and show the box of it, every card carrying its cursor" do
      page_html(@member, tags: "gwtest")
      assert_response :success
      assert_select ".modgal-grid[data-window]", 1
      assert_select ".modgal-grid[data-window-kind=key][data-more-ahead=true][data-more-behind=false]", 1
      assert_equal @ids.first(CHUNK), cards.map { it["data-id"].to_i }
      assert_equal CHUNK - SLOTS, cards.count { it["class"].split.include?("is-off") }
      assert cards.first(SLOTS).none? { it["class"].split.include?("is-off") }
      assert cards.all? { it["data-key"] == "#{it["data-id"]}~#{it["data-id"]}" }, "every card's cursor, from the card itself"

      # Without the script, next opens the first post past the box.
      assert_select ".modgal-pager a[rel=next][href*='anchor=#{@ids[SLOTS]}']", 1
      assert_select ".modgal-pager a[rel=prev][aria-disabled=true]:not([href])", 1
      assert_select ".modgal-pager", text: /#{CHUNK + 2} posts in this search/
      assert_select ".modgal-pager", text: /page/, count: 0
    end

    should "open at an anchor, with prev going back a box" do
      page_html(@member, tags: "gwtest", anchor: "#{@ids[SLOTS + 2]}~#{@ids[SLOTS + 2]}")
      assert_response :success
      assert_equal @ids[(SLOTS + 2)..], cards.map { it["data-id"].to_i }
      assert_select ".modgal-grid[data-more-behind=true][data-window-anchor='#{@ids[SLOTS + 2]}~#{@ids[SLOTS + 2]}']", 1
      assert_select ".modgal-pager a[rel=prev][href*='anchor=#{@ids[2]}']", 1
      assert_select ".modgal-pager a[rel=next][aria-disabled=true]", 1
    end

    should "serve a chunk with no layout and the same card markup" do
      page_html(@member, tags: "gwtest")
      id = @ids[SLOTS + 1]
      on_page = card_markup(id)

      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", anchor: "#{id}~#{id}", limit: CHUNK }
      assert_response :success
      assert_select ".modnav", 0
      assert_select "#blacklist-box", 0
      assert_select ".modgal-grid[data-window-v]", 1
      assert_equal on_page, card_markup(id)
      assert cards.all? { it["class"].split.include?("is-off") }, "a chunk arrives hidden; the window places it"
    end

    should "count nothing and remember nothing for a chunk" do
      PostSets::Post.any_instance.expects(:post_count).never
      ModulationSetting.expects(:record!).never
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest order:score", anchor: @ids[3].to_s }
      assert_response :success
    end

    should "count a random draw, which decides between a shuffle and a sample" do
      PostSets::Post.any_instance.expects(:post_count).at_least_once.returns(@posts.size)
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest order:random" }
      assert_response :success
      assert_select ".modgal-grid[data-window-kind=draw]", 1
    end

    should "send no blocklist data in a chunk" do
      @member.update!(blacklisted_tags: "secretblockword")
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", anchor: @ids[3].to_s }
      assert_response :success
      assert_not_includes response.body, "secretblockword"
    end

    should "refuse what it cannot serve, with the fix, and no page around it" do
      get_auth posts_path, create(:restricted_user), params: { preset: "modulation", variant: "window", tags: "gwtest" }
      assert_response 410
      assert_select ".modnav", 0
      assert_select ".modgal-window-error", text: /full account/

      get_auth posts_path, @member, params: { preset: "historical", variant: "window", tags: "gwtest" }
      assert_response 422
      assert_select ".modgal-window-error", text: /preset=modulation/

      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", anchor: @ids[1].to_s, before: @ids[3].to_s }
      assert_response 422
      assert_select ".modgal-window-error", text: /Fix: keep one of them/

      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest order:random", anchor: @ids[1].to_s }
      assert_response 422
      assert_select ".modgal-window-error", text: /fresh draw/

      get_auth posts_path, @member, params: { preset: "modulation", tags: "gwtest", anchor: "nonsense" }
      assert_response 422
    end

    should "refuse a time cursor past the range of time with the fix, not a database error" do
      [{}, { variant: "window" }].each do |extra|
        get_auth posts_path, @member, params: { preset: "modulation", tags: "gwtest order:created_at", anchor: "1~99999999999999999999", **extra }
        assert_response 422, extra.inspect
        assert_includes response.body, "That anchor is not a place in a search"
      end
    end

    # The client reads data-more-behind from a forward chunk nowhere, and
    # finding it out cost a second keyset query on every look ahead.
    should "look behind only where something reads the answer" do
      PostSets::Post.any_instance.expects(:window_behind).never
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", anchor: "#{@ids[5]}~#{@ids[5]}", limit: CHUNK }
      assert_response :success
      assert_select ".modgal-grid[data-more-ahead]", 1
      assert_select ".modgal-grid[data-more-behind]", 0

      # A backward chunk knows it for free, from the row past its limit.
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", before: "#{@ids[5]}~#{@ids[5]}", limit: CHUNK }
      assert_response :success
      assert_select ".modgal-grid[data-more-behind=false]", 1
    end

    # The count of a search is not what the viewer can see (it reads the
    # search as typed), so a draw says more only when it came back full.
    should "end a random draw that came back smaller than it asked, whatever the count says" do
      PostSets::Post.any_instance.stubs(:post_count).returns(500)
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest order:random", limit: 100 }
      assert_response :success
      assert_equal @posts.size, cards.size
      assert_select ".modgal-grid[data-window-kind=draw][data-more-ahead=false]", 1

      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest order:random", limit: CHUNK }
      assert_select ".modgal-grid[data-window-kind=draw][data-more-ahead=true]", 1
    end

    should "keep the API on its numbered pages" do
      get_auth "/posts.json", @member, params: { tags: "gwtest", page: 2, limit: 5 }
      assert_response :success
      assert_equal @ids[5..9], response.parsed_body.pluck("id")
      get_auth "/posts.json", @member, params: { tags: "gwtest", limit: 5, anchor: "nonsense" }
      assert_response :success, "anchor= means nothing outside the gallery"
    end

    should "never put a hidden post in a chunk, a cursor or a page" do
      Danbooru.config.stubs(:restricted_tags).returns(["gwgated"])
      gated = as(create(:user)) { create(:post, tag_string: "gwtest gwgated") }
      page_html(@member, tags: "gwtest")
      assert_select ".modgal-card[data-id='#{gated.id}']", 0
      assert_not_includes response.body, "#{gated.id}~"

      # A cursor naming the hidden post by its key opens the posts around it
      # and says nothing about it.
      get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "gwtest", anchor: "#{gated.id}~#{gated.id}" }
      assert_response :success
      assert_select ".modgal-card[data-id='#{gated.id}']", 0
      assert_equal @ids.first(CHUNK), cards.map { it["data-id"].to_i }

      get_auth posts_path, @member, params: { preset: "modulation", tags: "gwtest order:score", anchor: gated.id.to_s }
      hidden = response.body[/That post is not in this search[^<]*/]
      get_auth posts_path, @member, params: { preset: "modulation", tags: "gwtest order:score", anchor: "999999999" }
      assert_response 422
      assert_equal hidden, response.body[/That post is not in this search[^<]*/]
    end

    should "give a restricted viewer one page, no window and no cursor" do
      restricted = create(:restricted_user)
      page_html(restricted, tags: "gwtest")
      assert_response :success
      assert_select ".modgal-grid[data-window]", 0
      assert_equal SLOTS, cards.size
      assert cards.none? { it["data-key"] }
      assert_select ".modgal-pager a[rel=next][aria-disabled=true]", 1
      assert_select ".modgal-capped", 1

      get_auth posts_path, restricted, params: { preset: "modulation", tags: "gwtest", anchor: @ids[3].to_s }
      assert_response 410
    end

    should "say where a position-based sort may shift" do
      page_html(@member, tags: "gwtest order:comment_bumped")
      assert_select ".modgal-grid[data-window-kind=offset]", 1
      assert_equal "@0", cards.first["data-key"]
      assert_select ".modgal-pager", text: /position-based sort: results may shift/
    end

    should "carry the panel's remembered sort into the window's own tags" do
      ModulationSetting.record!(@member, nil, { "gallery_sort" => "score" })
      page_html(@member, tags: "gwtest")
      assert_select ".modgal-grid[data-window-tags='gwtest order:score']", 1
    end
  end
end
