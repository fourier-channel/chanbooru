# frozen_string_literal: true

require "test_helper"

# The interface switch (app/logical/interface.rb, ExperiencePreset's plug):
# an interface's views go in front of upstream's for one request only, fall
# through one page and one variant at a time, and hold for error pages too.
#
# The fixture interface under test/files/interfaces/fixture draws three pages,
# each marking itself: posts/show, sessions/new and static/error.
class InterfaceSwitchTest < ActionDispatch::IntegrationTest
  FIXTURE = Interface.new(number: 99, name: "fixture", folder: Rails.root.join("test/files/interfaces/fixture"))

  def first_paths = controller.lookup_context.view_paths.to_a
  def copies_of(resolver) = first_paths.count { |path| path.equal?(resolver) }

  def use_fixture!
    ApplicationController.any_instance.stubs(:current_interface).returns(FIXTURE)
  end

  context "A Modulation request" do
    should "put Modulation's resolver first for that request and leave the class-wide view paths alone" do
      modulation = Interface.fetch("modulation")
      class_wide = ApplicationController.view_paths.to_a

      get login_path(preset: "modulation", preset_sticky: "0")

      assert_response :success
      assert_same(modulation.resolver, first_paths.first, "the request's first view path is Modulation's resolver")
      assert_equal(1, copies_of(modulation.resolver), "one copy of the resolver")
      assert_equal(class_wide, ApplicationController.view_paths.to_a, "the class-wide view paths are unchanged")
      assert_equal(class_wide, ActionController::Base.view_paths.to_a, "ActionController::Base's view paths are unchanged")
    end

    should "never reach a classic request running beside it on another thread" do
      seen = Queue.new
      threads = %w[modulation historical].map do |preset|
        Thread.new do
          browser = open_session
          4.times do
            browser.get login_path(preset: preset, preset_sticky: "0")
            seen << [preset, browser.response.status, browser.controller.lookup_context.view_paths.to_a.grep(InterfaceResolver)]
          end
        end
      end
      threads.each(&:join)

      results = Array.new(seen.size) { seen.pop }
      assert_equal(8, results.size)
      results.each do |preset, status, resolvers|
        assert_equal(200, status, "#{preset} answered #{status}")
        expected = (preset == "modulation") ? [Interface.fetch("modulation").resolver] : []
        assert_equal(expected, resolvers, "the view paths of a #{preset} request")
      end
    end
  end

  context "A classic request" do
    should "look only where upstream's controllers look" do
      get login_path

      assert_response :success
      assert_equal(ApplicationController.view_paths.to_a, first_paths)
    end
  end

  context "An interface's resolver" do
    setup do
      use_fixture!
      @post = create(:post)
      @member = create(:user)
    end

    should "draw the interface's page where it has one" do
      get login_path
      assert_response :success
      assert_includes(response.body, "fixture-interface sessions/new")

      get_auth post_path(@post), @member
      assert_response :success
      assert_includes(response.body, "fixture-interface posts/show")
    end

    should "fall through to upstream's file for a variant the interface does not draw" do
      get_auth post_path(@post, variant: "tooltip", preview: "true"), @member

      assert_response :success
      assert_not_includes(response.body, "fixture-interface")
      assert_includes(response.body, "post-tooltip-header", "upstream's posts/show.html+tooltip")
      assert_not_includes(response.body, "<html", "the tooltip is drawn with no layout")
    end

    should "answer a variant upstream has no file for with the interface's plain page" do
      get login_path(variant: "tooltip")

      assert_response :success
      assert_includes(response.body, "fixture-interface sessions/new")
    end

    # Why the resolver exists: the same fixture as a plain folder in front
    # would answer the tooltip with its whole page.
    should "be needed: a plain folder in front would answer the tooltip" do
      plain = ActionView::PathRegistry.cast_file_system_resolvers(FIXTURE.folder.join("views").to_s)
      lookup = ActionView::LookupContext.new(plain + ApplicationController.view_paths.to_a, variants: [:tooltip], formats: [:html])
      assert_match(%r{fixture/views/posts/show\.html\.erb\z}, lookup.find("show", ["posts"]).identifier)

      lookup = ActionView::LookupContext.new([FIXTURE.resolver] + ApplicationController.view_paths.to_a, variants: [:tooltip], formats: [:html])
      assert_match(%r{app/views/posts/show\.html\+tooltip\.erb\z}, lookup.find("show", ["posts"]).identifier)
    end
  end

  context "An error page" do
    setup { use_fixture! }

    should "draw under the interface when the error comes before set_variant" do
      get login_path, env: { "rack.input" => StringIO.new("x=1"), "CONTENT_LENGTH" => "3" }

      assert_response 400
      assert_includes(response.body, "fixture-interface static/error")
      assert_same(FIXTURE.resolver, first_paths.first)
      assert_equal(1, copies_of(FIXTURE.resolver))
    end

    should "draw under the interface, with one copy of its resolver, when a template fails after the plug" do
      get login_path(fixture_fail: "1")

      assert_response 500
      assert_includes(response.body, "fixture-interface static/error")
      assert_same(FIXTURE.resolver, first_paths.first)
      assert_equal(1, copies_of(FIXTURE.resolver))
    end
  end

  context "A request body the parser refuses" do
    should "answer 400 under the session's interface, not 500 from reading the preset" do
      modulation = Interface.fetch(ExperiencePreset::MODULATION)
      get login_path(preset: ExperiencePreset::MODULATION)
      # PumaTest's request: upstream's HTML layout reads request.params itself.
      raised = begin
        post "/posts", params: '{"a": ', headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json", "X-Http-Method-Override" => "GET" }
        nil
      rescue StandardError => e
        e
      end

      assert_nil(raised, "the error page raised reading the preset: fix: resolve_experience_preset rescues a refused body (app/logical/concerns/experience_preset.rb)")
      assert_response 400
      assert_equal(ExperiencePreset::MODULATION, controller.experience_preset)
      assert_same(modulation.resolver, first_paths.first)
    end
  end

  context "The GoodJob dashboard" do
    should "refuse a signed-out viewer, not answer 500" do
      # Raised inside GoodJob's error handler, a missing plug is a 500 in
      # production and an exception here: either way, a failure.
      raised = begin
        get "/good_job/jobs"
        nil
      rescue StandardError => e
        e
      end
      assert_nil(raised, "GoodJob's error handler raised: fix: keep its no-op use_interface_views (config/initializers/good_job.rb)")
      assert_includes([403, 404], response.status, "a signed-out GET /good_job/jobs answered #{response.status}")
    end
  end
end
