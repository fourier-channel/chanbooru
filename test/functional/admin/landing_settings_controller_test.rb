require "test_helper"

# The front page is the shop window, so re-aiming it is an admin act.
#
# WHICH FORM DOES WHAT, since 2026-09-17. The console carries two: the
# carousel-wide LandingSetting (the slide speed), and the Categories form, one
# fieldset per LandingCategory row -- which is where the "new" row's board,
# heading and fresh-only toggle live, because that table is what
# LandingShowcase reads (8b8f06cee). This file used to re-aim the front page
# through LandingSetting and read the result from LandingShowcase.categories;
# that class method went with 8b8f06cee and so did LandingSetting's say over
# the row, while the console went on offering the dead fields. The re-aim is
# tested here through the form that actually does it, through to the showcase.
class Admin::LandingSettingsControllerTest < ActionDispatch::IntegrationTest
  TRASH = "https://boards.4chan.org/trash/thread/1#p2"

  context "the landing setting panel" do
    setup do
      @admin = create(:admin_user)
      @user = create(:user)
    end

    should "not be reachable by an ordinary user" do
      get_auth admin_landing_setting_path, @user
      assert_response 403
    end

    should "not be reachable anonymously" do
      # A flat refusal rather than a redirect to a login: this fork answers 403
      # here, which is the better answer -- an admin page should not advertise
      # itself to a stranger by inviting them to sign in.
      get admin_landing_setting_path
      assert_response 403
    end

    should "render for an admin" do
      get_auth admin_landing_setting_path, @admin
      assert_response :success
    end

    should "offer one control for the new row's target, not two" do
      # The carousel-wide form carried a heading, a board and a fresh-only
      # toggle for a week after nothing read them, and saving them said "The
      # front page now shows ..." while it did not.
      get_auth admin_landing_setting_path, @admin
      assert_response :success
      %w[board label fresh_only].each do |attr|
        assert_select "[name='landing_setting[#{attr}]']", count: 0
      end
      assert_select "[name='landing_categories[new][board]']", count: 1
      assert_select "[name='landing_setting[advance_ms]']", count: 1
    end

    should "change the slide speed" do
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { advance_ms: "9000" }}
      assert_redirected_to admin_landing_setting_path
      assert_equal 9000, LandingSetting.current.advance_ms
    end

    should "change what the front page shows" do
      binned = as(@user) { create(:post, source: TRASH) }

      login_as(@admin)
      patch categories_admin_landing_setting_path, params: {
        landing_categories: { new: { enabled: "1", label: "From the bin", board: "trash", fresh_only: "0", ordering: "new" }},
      }

      assert_redirected_to admin_landing_setting_path
      assert_equal ["source:https://boards.4chan.org/trash/*"], LandingCategory.find_by!(key: "new").queries
      row = LandingShowcase.new(viewer: User.anonymous).categories.find { |c| c[:key] == "new" }
      assert_not_nil row, "the new row came back empty, so it did not search /trash/"
      assert_equal "From the bin", row[:label]
      assert_includes row[:slides].pluck(:id), binned.id
    end

    should "show the blog row with the address it reads, and no search controls" do
      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog]", 1
      assert_select "[name='landing_categories[blog][enabled]'][type=checkbox]", 1
      assert_select "[name='landing_categories[blog][label]']", 1
      assert_select "[name='landing_categories[blog][ordering]']", 0
      assert_select "[name='landing_categories[blog][tags_string]']", 0
      assert_select "fieldset[data-key=blog] code", text: LandingBlogCache.index_url
      assert_select "fieldset[data-key=blog] [data-blog-status=never]", 1
    end

    should "say what the last read of the blog found" do
      seed_blog

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=ok]", text: /2 posts/
    end

    should "say when the last read of the blog failed, and what is still shown" do
      seed_blog(now: 1.hour.ago)
      stub_blog_index("oops", status: 500, content_type: "text/plain")
      assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=failed]", text: /500/
      assert_select "fieldset[data-key=blog] [data-blog-status=failed]", text: /still showing 2 posts/
    end

    # An unmeasured read must not render as a healthy one: an ok status that
    # is far older than the refresh clock means nothing has tried since.
    should "say when the blog has not been read for longer than the clock allows" do
      seed_blog(now: 1.hour.ago)

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=stalled]", 1
    end

    should "turn the blog row off" do
      seed_blog

      login_as(@admin)
      patch categories_admin_landing_setting_path, params: {
        landing_categories: { blog: { enabled: "0", label: "Blog" }},
      }

      assert_redirected_to admin_landing_setting_path
      assert_not LandingCategory.find_by!(key: "blog").enabled?
      assert_nil LandingShowcase.new(viewer: User.anonymous).categories.find { it[:key] == "blog" }
    end

    should "refuse a board slug that is really a search, and say so" do
      login_as(@admin)
      patch categories_admin_landing_setting_path, params: {
        landing_categories: { new: { enabled: "1", label: "Sneaky", board: "b -no_train", fresh_only: "1", ordering: "new" }},
      }

      assert_response :unprocessable_entity
      assert_match(/is a board slug like/, response.body)
      assert_not_equal "b -no_train", LandingCategory.find_by(key: "new")&.board
    end
  end
end
