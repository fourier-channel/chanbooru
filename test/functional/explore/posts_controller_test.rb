require "test_helper"

module Explore
  class PostsControllerTest < ActionDispatch::IntegrationTest
    context "in all cases" do
      setup do
        @post = create(:post)
      end

      context "#popular" do
        should "render" do
          get popular_explore_posts_path
          assert_response :success
        end

        should "work with a blank date" do
          get popular_explore_posts_path(date: "")
          assert_response :success
        end

        # Modulation draws its own popular page (app/interfaces/modulation/
        # views); the test default is historical, so these ask for it by name.
        context "under Modulation" do
          setup do
            @member = create(:user)
          end

          should "draw the popular posts as a strip, with the date navigation and the paginator" do
            get_auth popular_explore_posts_path(preset: "modulation", preset_sticky: 0), @member

            assert_response :success
            assert_select "#c-explore-posts #a-popular .mod-ui h1.mod-subject .mod-subject-prefix", text: "Popular:"
            assert_select "a#paginator-prev[data-shortcut]"
            assert_select "section.modstrip a.modgal-card[data-id=?]", @post.id.to_s
            assert_select "p.modstrip-empty", count: 0
          end

          should "say there are no posts past the end, and keep the way back" do
            get_auth popular_explore_posts_path(page: 9, preset: "modulation", preset_sticky: 0), @member

            assert_response :success
            assert_select "a.modgal-card", count: 0
            assert_select "section.modstrip p.modstrip-empty", text: "No posts found."
            assert_select "section.modstrip a.paginator-prev"
          end
        end
      end
    end
  end
end
