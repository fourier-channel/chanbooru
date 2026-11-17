# frozen_string_literal: true

require "test_helper"

# NavSurface decides what the site header offers a viewer (interfaces stage
# 1, step 4a); ModulationNavbarComponent draws what it returns. What each
# viewer is offered is pinned by the parity and privacy recordings; this
# pins the shape that makes them hold for every interface: the surface
# decides for the viewer it is handed, never for CurrentUser, and the
# component decides nothing.
class NavSurfaceTest < ActiveSupport::TestCase
  COMPONENT = %w[
    app/interfaces/modulation/components/modulation_navbar_component.rb
    app/interfaces/modulation/components/modulation_navbar_component/modulation_navbar_component.html.erb
  ].freeze
  # A decision, a policy or a query: what the component must leave to the
  # surface.
  DECIDING = /\bCurrentUser\b|\bMembersOnly\b|Policy\b|\bpolicy\(|\.is_\w+\?|\.(?:pending|count|where|find_by)\b|\b(?:ModulationSetting|SessionObservation|TagQuarantine)\b/

  def surface_for(viewer, session = {})
    request = ActionDispatch::TestRequest.create
    request.session = session
    NavSurface.new(viewer: viewer, request: request, session: request.session)
  end

  def labels(surface)
    surface.entries.pluck(:label)
  end

  context "NavSurface" do
    setup do
      @owner = create(:owner_user)
    end

    should "decide for the viewer it is handed, never for CurrentUser" do
      signed_out = CurrentUser.scoped(@owner) { labels(surface_for(User.anonymous)) }
      owner = CurrentUser.scoped(User.anonymous) { labels(surface_for(@owner)) }

      assert_not_includes(signed_out, "Sample", "the signed-out header was decided for CurrentUser (the owner); fix: NavSurface asks its `viewer`, never CurrentUser")
      assert_not_includes(signed_out, "Reports")
      assert_includes(owner, "Sample", "the owner's header was decided for CurrentUser (signed out); fix: NavSurface asks its `viewer`, never CurrentUser")
      assert_includes(owner, "Reports")
    end

    should "read a signed-out viewer's settings from the session it is handed, and observe it" do
      surface = surface_for(User.anonymous, { ModulationSetting::SESSION_KEY => { "session_bar_open" => true }})

      assert_equal(true, surface.session_bar_open?)
      assert_equal("cookie:#{Danbooru.config.session_cookie_name}", surface.observation.dig(:booru, :expect))
    end
  end

  context "ModulationNavbarComponent" do
    should "decide nothing: no viewer check, policy or query of its own" do
      found = COMPONENT.flat_map do |path|
        Rails.root.join(path).readlines.each_with_index.filter_map { |line, i| "#{path}:#{i + 1}: #{line.strip}" if line.match?(DECIDING) }
      end

      assert_empty(found, "the header component decides again; fix: move each into NavSurface (app/logical/nav_surface.rb) and draw what it returns")
    end
  end
end
