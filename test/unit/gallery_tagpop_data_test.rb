require "test_helper"

# The hover panel's pills are drawn client-side from two maps the gallery puts
# on the grid: name -> category (which decides the COLOUR) and name -> count.
# A pill is therefore only ever as right as these maps, so each category is
# checked on its own and then all five together on one page.
#
# Driven through the real request rather than by constructing the component,
# because the attribute on the page is the thing the browser actually reads.
class GalleryTagpopDataTest < ActionDispatch::IntegrationTest
  CATEGORIES = {
    "artist" => TagCategory::ARTIST,
    "copyright" => TagCategory::COPYRIGHT,
    "character" => TagCategory::CHARACTER,
    "meta" => TagCategory::META,
    "general" => TagCategory::GENERAL,
  }.freeze

  def grid_maps
    grid = css_select(".modgal-grid").first
    [JSON.parse(grid["data-tag-categories"] || "{}"), JSON.parse(grid["data-tag-counts"] || "{}")]
  end

  context "each category on its own" do
    CATEGORIES.each do |key, int|
      should "colour a #{key} tag as #{key}" do
        user = create(:user)
        create(:tag, name: "solo_#{key}", category: int)
        as(user) { create(:post, tag_string: "solo_#{key}") }
        get posts_path(preset: "modulation", tags: "solo_#{key}")
        assert_response :success
        cats, = grid_maps
        assert_equal key, cats["solo_#{key}"], "solo_#{key} should map to #{key}, got #{cats["solo_#{key}"].inspect}"
      end
    end
  end

  context "all five together on one page" do
    setup do
      @user = create(:user)
      CATEGORIES.each { |key, int| create(:tag, name: "mixed_#{key}", category: int) }
      as(@user) { create(:post, tag_string: CATEGORIES.keys.map { |k| "mixed_#{k}" }.join(" ")) }
      get posts_path(preset: "modulation", tags: "mixed_general")
      assert_response :success
    end

    should "give every tag its own category, with none bleeding into another" do
      cats, = grid_maps
      CATEGORIES.each_key { |key| assert_equal key, cats["mixed_#{key}"], "mixed_#{key} should be #{key}" }
      assert_equal CATEGORIES.keys.sort, CATEGORIES.keys.map { |k| cats["mixed_#{k}"] }.sort
    end

    should "carry a count for every tag it admits" do
      cats, counts = grid_maps
      assert_equal cats.keys.sort, counts.keys.sort,
        "every tag the panel may display needs a count, or a pill shows a name with no number"
      counts.each_value { |n| assert_kind_of Integer, n }
    end
  end
end
