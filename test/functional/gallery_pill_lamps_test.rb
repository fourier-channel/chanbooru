require "test_helper"

# /posts's pills in formant: the dot is the LAMP -- which model put the tag
# there -- and the words are white on every pill, which the stylesheet decides
# from these classes (operator, 2026-09-25: "get /posts's tag elements into
# formant compliance"). The gallery's dots used to show the provenance bucket,
# and its grouped view drew no dot at all.
#
# Driven through the real request, like gallery_tagpop_data_test: the markup
# on the page is what the browser styles.
class GalleryPillLampsTest < ActionDispatch::IntegrationTest
  S = FourierTagSource::AUTO | FourierTagSource::SPECTRUM
  H = FourierTagSource::AUTO | FourierTagSource::HYDRA

  def dot_for(tag, scope = ".mod-unitag")
    pill = css_select("#{scope} a.mod-pill").find { |a| a["href"].to_s.include?("tags=#{tag}") }
    assert pill, "no pill for #{tag} in #{scope}"
    dot = pill.at_css(".mod-pill-dot")
    assert dot, "the #{tag} pill in #{scope} has no dot"
    dot["class"].split.find { |c| c.start_with?("mod-pill-dot--") }
  end

  setup do
    @user = create(:user)
    %w[lamp_spectrum lamp_hydra lamp_both lamp_hand].each { |n| create(:tag, name: n, category: TagCategory::GENERAL) }
    @post = as(@user) { create(:post, tag_string: "lamp_spectrum lamp_hydra lamp_both lamp_hand") }
    { "lamp_spectrum" => S, "lamp_hydra" => H, "lamp_both" => S | H }.each do |tag, source|
      FourierTagSource.create!(post: @post, tag: tag, source: source, status: FourierTagSource::APPROVED, public: true, created_at: Time.zone.now)
    end
    get posts_path(preset: "modulation", tags: "lamp_hand")
    assert_response :success
  end

  should "light each pill's dot for the model that put the tag there" do
    assert_equal "mod-pill-dot--spectrum", dot_for("lamp_spectrum")
    assert_equal "mod-pill-dot--hydra", dot_for("lamp_hydra")
    assert_equal "mod-pill-dot--both", dot_for("lamp_both")
    # no row: no model put it there, and the lamp says so in white
    assert_equal "mod-pill-dot--manual", dot_for("lamp_hand")
  end

  should "draw the same lamps in the grouped view" do
    assert_equal "mod-pill-dot--hydra", dot_for("lamp_hydra", ".mod-grouped")
    assert_equal "mod-pill-dot--manual", dot_for("lamp_hand", ".mod-grouped")
  end

  should "name the tag on the pill, for the hype mark" do
    pill = css_select(".mod-unitag a.mod-pill").find { |a| a["href"].to_s.include?("tags=lamp_hydra") }
    assert_equal "lamp_hydra", pill["data-tag"]
  end
end
