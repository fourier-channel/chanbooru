# frozen_string_literal: true

require "test_helper"

# The heading of a Modulation subject page: the subject as a pill in its
# category's paint, its count, its state chips, and the h1 id upstream's
# script and tests key off.
class ModulationSubjectHeaderComponentTest < ViewComponent::TestCase
  should "draw the subject as a linked pill in its category's paint, with its count and badges" do
    render_inline(ModulationSubjectHeaderComponent.new(name: "pv artist", href: "/posts?tags=pv_artist", category_key: "artist", count: 12, badges: ["Banned", nil, ""], prefix: "Artist"))

    assert_css("h1.mod-subject > span.mod-label.mod-subject-prefix", text: "Artist")
    assert_css("h1.mod-subject > a.mod-pill.mod-pill--subject.mod-pill--cat.mod-pill--cat-artist[href='/posts?tags=pv_artist']", text: "pv artist")
    assert_css("h1.mod-subject > .mod-subject-count", text: "12")
    assert_css("h1.mod-subject > span.mod-label.mod-badge", count: 1, text: "Banned")
  end

  should "pass its id through to the h1" do
    render_inline(ModulationSubjectHeaderComponent.new(name: "scenery", id: "wiki-page-title"))

    assert_css("h1#wiki-page-title.mod-subject")
  end

  should "draw a plain pill with no category, count or badges when given none" do
    render_inline(ModulationSubjectHeaderComponent.new(name: "nonesuch"))

    assert_css("h1.mod-subject > span.mod-pill.mod-pill--subject", text: "nonesuch")
    assert_no_css(".mod-pill--cat")
    assert_no_css(".mod-subject-count")
    assert_no_css(".mod-badge")
    assert_no_css("h1[id]")
  end

  should "draw a zero count" do
    render_inline(ModulationSubjectHeaderComponent.new(name: "empty", count: 0))

    assert_css(".mod-subject-count", text: "0")
  end
end
