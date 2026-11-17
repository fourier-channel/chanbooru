# frozen_string_literal: true

require "test_helper"

# The Modulation post view draws what its PostSurface returned (interfaces
# stage 1, step 4c) and decides nothing of its own.
class ModulationPostComponentTest < ViewComponent::TestCase
  FILES = %w[
    app/interfaces/modulation/components/modulation_post_component.rb
    app/interfaces/modulation/components/modulation_post_component/modulation_post_component.html.erb
  ].freeze
  # A viewer read from the thread, a policy, or a decision the surface makes:
  # what the component must leave to it. Matched with comments removed.
  DECIDING = /\bCurrentUser\b|Policy\b|\bpolicy\b|\bPundit\b|\.update\?|\.visible\?|\.hidden_from\?|\b(?:TagBanishment|TagQuarantine|FourierTagSource|FourierCreatorPrivacy|CreatorVisibility|MembersOnly|ModulationSetting)\b/

  should "draw the payload and the media box the surface returned" do
    member = create(:user)
    post = as(member) { create(:post, tag_string: "pcomp") }
    surface = PostSurface.new(post: post, viewer: member, request: vc_test_request, session: vc_test_request.session)
    handed = { id: post.id, media: { kind: "image", box: [123, 45] }, sentinel: "drawn as handed" }
    surface.stubs(:payload).returns(handed).once

    CurrentUser.scoped(member) { render_inline(ModulationPostComponent.new(surface: surface)) }

    assert_equal(handed.as_json, JSON.parse(page.find("#modulation-root")["data-payload"]), "the component did not draw the payload its surface returned; fix: the template embeds surface.payload as data-payload")
    assert_includes(page.find(".mod-stage-center")["style"].to_s, "--mod-bw:123;--mod-bh:45", "the stage was not sized from the surface's media box; fix: the template sizes .mod-stage-center from payload[:media][:box]")
  end

  should "decide nothing: no CurrentUser, policy or visibility call of its own" do
    found = FILES.flat_map do |path|
      source = Rails.root.join(path).read
      # ERB comments, and the script's own whole-line comments, which name
      # the server objects the payload came from.
      source = path.end_with?(".erb") ? source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") }.gsub(%r{^\s*//.*$}, "") : source.gsub(/^\s*#.*$/, "")
      source.lines.each_with_index.filter_map { |line, i| "#{path}:#{i + 1}: #{line.strip}" if line.match?(DECIDING) }
    end

    assert_empty(found, "the post view decides again; fix: move each into PostSurface (app/logical/post_surface.rb) and draw what it returns")
  end
end
