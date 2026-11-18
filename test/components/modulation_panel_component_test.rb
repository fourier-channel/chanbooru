# frozen_string_literal: true

require "test_helper"

# The one Modulation panel: a labelled section around its content.
class ModulationPanelComponentTest < ViewComponent::TestCase
  should "draw a labelled panel around its content, with its id and classes" do
    render_inline(ModulationPanelComponent.new(label: "Other names", id: "artist-other-names", classes: "artist-other-names")) { "pv_alias" }

    assert_css("section#artist-other-names.mod-panel.artist-other-names > h2.mod-label.mod-panel-label", text: "Other names")
    assert_css("section.mod-panel", text: /pv_alias/)
  end

  should "draw no label when given none" do
    render_inline(ModulationPanelComponent.new) { "body" }

    assert_css("section.mod-panel", text: "body")
    assert_no_css("h2")
    assert_no_css("section[id]")
  end
end
