# frozen_string_literal: true

require "test_helper"

# NOTICES SIT BELOW THE IMAGE (operator, 2026-10-18). The notice strip -- a
# deletion, a flag, a post's parent or children -- used to be a section of the
# page above the stage, so landing on a post that had one moved the stage, and
# everything under it, down by the strip's height (~51 px at 1280, ~78 at 375,
# bin/postview-shift). The client now draws the notices in the tag panel under
# its head (renderTags), from the payload; the shell above the stage has none.
class ModulationNoticesPlacementTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = create(:user)
    @parent = create(:post)
    @child = create(:post, parent: @parent)
  end

  should "render no notice strip above the stage, and hand the notices to the client" do
    get_auth post_path(@child, preset: "modulation"), @viewer
    assert_response :success

    order = css_select(".modulation > *").map { |el| el["class"].to_s.split.first }
    assert_includes order, "mod-stage"
    assert_empty css_select(".modulation > .mod-notices"), "no notice section in the shell: #{order.inspect}"

    payload = JSON.parse(css_select(".modulation").first["data-payload"])
    assert_equal ["parent"], payload["notices"].pluck("kind"), "the payload still carries the notices for the tag panel"
  end
end
