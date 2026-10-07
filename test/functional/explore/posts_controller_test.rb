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
      end
    end
  end
end
