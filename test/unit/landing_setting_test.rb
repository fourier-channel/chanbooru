require "test_helper"

# The error page's pictures (operator, 2026-10-11): booru posts named by id on
# the landing console, one drawn at random on each load of the "Oh No!" page.
# The list is held to what it can mean: real posts, each once, a bounded
# number of them -- and a typo is refused by name, never saved to find nothing.
class LandingSettingTest < ActiveSupport::TestCase
  context "the error page's pictures" do
    setup do
      @posts = create_list(:post, 3)
      @setting = LandingSetting.current
    end

    should "be empty by default" do
      assert_equal [], LandingSetting.new.error_page_post_ids
    end

    should "take ids separated by spaces, commas and newlines, in the order given" do
      a, b, c = @posts.map(&:id)
      @setting.error_page_post_ids_text = "#{c}, #{a}\n#{b}"

      assert @setting.save, @setting.errors.full_messages.join("; ")
      assert_equal [c, a, b], @setting.reload.error_page_post_ids
    end

    should "drop a repeated id rather than refuse it" do
      a, b, = @posts.map(&:id)
      @setting.error_page_post_ids_text = "#{a} #{b} #{a}"

      assert @setting.save
      assert_equal [a, b], @setting.reload.error_page_post_ids
    end

    should "drop a repeat assigned as an array, too" do
      a, = @posts.map(&:id)
      @setting.error_page_post_ids = [a, a]

      assert @setting.save
      assert_equal [a], @setting.reload.error_page_post_ids
    end

    should "save an empty list, which draws the placeholder" do
      @setting.update!(error_page_post_ids: @posts.map(&:id))
      @setting.error_page_post_ids_text = "  \n "

      assert @setting.save
      assert_equal [], @setting.reload.error_page_post_ids
    end

    should "refuse an id that names no post, naming it and saying what to do" do
      a, = @posts.map(&:id)
      @setting.error_page_post_ids_text = "#{a} 999999991 999999992"

      assert_not @setting.save
      message = @setting.errors.full_messages.join("; ")
      assert_match(/#999999991/, message)
      assert_match(/#999999992/, message)
      assert_match(/remove|correct/i, message)
      assert_no_match(/##{a}\b/, message)
    end

    should "refuse something that is not a post id, naming it" do
      a, = @posts.map(&:id)
      @setting.error_page_post_ids_text = "#{a} abc 0 -4 12.5"

      assert_not @setting.save
      message = @setting.errors.full_messages.join("; ")
      %w[abc 0 -4 12.5].each { |token| assert_includes message, "\"#{token}\"" }
    end

    should "refuse a non-positive id assigned as an array" do
      @setting.error_page_post_ids = [0, -3]

      assert_not @setting.valid?
      assert_match(/positive/, @setting.errors.full_messages.join("; "))
    end

    should "refuse more than the cap, saying how many there were" do
      ids = (1..(LandingSetting::ERROR_PAGE_POSTS_MAX + 1)).to_a
      @setting.error_page_post_ids = ids

      assert_not @setting.valid?
      message = @setting.errors.full_messages.join("; ")
      assert_match(/#{LandingSetting::ERROR_PAGE_POSTS_MAX}/o, message)
      assert_match(/#{ids.size} posts/, message)
    end

    should "keep what was typed when it is refused, so the form can show it again" do
      @setting.error_page_post_ids_text = "1 2 nope"

      assert_not @setting.save
      assert_equal "1 2 nope", @setting.error_page_post_ids_text
    end

    should "not block saving the slide speed when a listed post was expunged later" do
      @setting.update!(error_page_post_ids: @posts.map(&:id))
      LandingSetting.connection.execute("UPDATE landing_settings SET error_page_post_ids = '{#{@posts.first.id},999999993}' WHERE id = #{@setting.id}")
      @setting.reload
      @setting.advance_ms = 7000

      assert @setting.save, @setting.errors.full_messages.join("; ")
    end
  end
end
