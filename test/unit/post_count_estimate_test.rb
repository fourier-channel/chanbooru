# frozen_string_literal: true

require "test_helper"

# Counts are not a visibility surface (operator, 2026-10-17: "The tag count
# doesn't need to be the same and it also doesn't need to be different. It's
# a non issue altogether. People will understand that not every post is going
# to be visible."). The cheap estimates -- one tag from the tags table, a
# blank search, a rating -- read the search as typed, not with the terms the
# viewer's situation adds (hidden ids, gated, deleted, banished): with those
# terms every count of a popular search was an exact count over the whole
# posts table, past the 1 s count timeout (production, 2026-10-15..17: 263 of
# 273 statement timeouts), and the page lost its count.
#
# Two lines hold. A count never confirms ONE hidden post: a search the
# estimates do not cover (id:, md5:, several tags) is still counted exactly
# over what the viewer may see. And a tag name hidden from the viewer
# (Tag.hidden_names_for) counts 0, as a name never used does.
class PostCountEstimateTest < ActiveSupport::TestCase
  def count(search, user, safe_mode: false)
    PostQuery.normalize(search, current_user: user, safe_mode: safe_mode).with_implicit_metatags.fast_count
  end

  # A gated post is one a member cannot see (Post#hidden_as_gated?).
  setup do
    Danbooru.config.stubs(:restricted_tags).returns(["gatedname"])
    @member = create(:user)
    @gold = create(:gold_user)
    @shown = create(:post, tag_string: "landscape")
    # A 32-hex md5: the factory's 64-hex one never parses as an md5: search,
    # so an md5 assertion on it would pass for every viewer.
    @gated = create(:post, tag_string: "landscape gatedname", md5: SecureRandom.hex(16))
  end

  should "estimate one tag from the tags table, whatever the viewer cannot see" do
    assert_equal 2, Tag.find_by_name("landscape").post_count
    assert_equal 2, count("landscape", @member)
    assert_equal 1, PostQuery.normalize("landscape", current_user: @member).with_implicit_metatags.posts.count
  end

  should "estimate a blank search without the viewer's terms" do
    assert_equal Post.count, PostQuery.normalize("", current_user: @member).with_implicit_metatags.fast_count(estimate_count: true)
  end

  should "count a search for one post exactly over what the viewer may see" do
    assert_equal 0, count("id:#{@gated.id}", @member)
    assert_equal 1, count("id:#{@gated.id}", @gold)
    assert_equal 0, count("md5:#{@gated.md5}", @member)
    assert_equal 0, count("md5:#{@gated.md5}", User.anonymous)
    assert_equal 1, count("md5:#{@gated.md5}", @gold)
  end

  # A remembered gallery sort appends order:<sort> to every search; an order
  # that only re-sorts leaves the estimate standing. One that drops rows
  # (order:artcomm inner-joins the commentaries) is counted exactly.
  should "estimate past an order that only re-sorts, and not past one that drops rows" do
    assert_equal 2, count("landscape order:id_desc", @member)
    assert_equal 2, count("landscape order:score", @member)
    assert_equal 2, count("landscape order:comment", @member)
    assert_equal Post.count, count("order:random", @member)

    as(@gold) { create(:artist_commentary, post: @gated) }
    assert_equal 0, count("order:artcomm", @member)
    assert_equal 1, count("order:artcomm", @gold)
  end

  # Every listed order keeps every row: the exact count with it equals the
  # exact count without it.
  should "list only orders that keep every row" do
    exact = ->(search) { PostQuery.normalize(search, current_user: @gold).with_implicit_metatags.fast_count(estimate_count: false, skip_cache: true) }
    PostQuery::REORDER_ONLY_ORDERS.each do |order|
      assert_equal exact.call("landscape"), exact.call("landscape order:#{order}"), order
    end
  end

  # The 0 for a hidden name is answered without counting posts: falling
  # through to the exact count gives 0 too, over the whole posts table.
  should "answer a hidden name without counting posts" do
    PostQuery.any_instance.expects(:exact_count).never
    assert_equal 0, count("gatedname", @member)
  end

  # A viewer below Gold who may see SOME posts of a gated name -- their own
  # uploads, a creator's allow -- is counted exactly, not 0: a 0 there left
  # the paginator no next page for rows they can see, and related tags
  # divided by it.
  should "count a gated name exactly for a viewer let in to some of its posts" do
    uploader = create(:user)
    as(uploader) { create(:post, tag_string: "gatedname", uploader: uploader) }

    assert_equal 1, count("gatedname", uploader)
    assert_equal 0, count("gatedname", @member)
    assert_nothing_raised { RelatedTagQuery.new(query: "gatedname", user: uploader).related_tags.to_a }
    assert_equal [], RelatedTagQuery.new(query: "gatedname", user: @member).related_tags.to_a
  end

  # Safe mode's own terms stay in the estimate, so a safe-mode search is no
  # longer one tag and is counted exactly over what safe mode shows.
  should "keep safe mode's terms in the count" do
    create(:post, tag_string: "landscape", rating: "g")
    create(:post, tag_string: "landscape", rating: "e")

    assert_equal 4, count("landscape", @gold)
    assert_equal 1, count("landscape", @gold, safe_mode: true)
    assert_equal 0, count("rating:e", @gold, safe_mode: true)
  end

  should "count a tag name hidden from the viewer as 0, as a name never used" do
    assert_equal 0, count("gatedname", @member)
    assert_equal 1, count("gatedname", @gold)
  end
end
