require "test_helper"

class TagChangeNoticeComponentTest < ViewComponent::TestCase
  context "The TagChangeNoticeComponent" do
    should "render pending bulk update request notices" do
      user = create(:user)
      tag = create(:tag, name: "aaa")
      create(:bulk_update_request, user: user, script: "create alias aaa -> bbb")

      as(user) do
        render_inline(TagChangeNoticeComponent.new(tag: tag, current_user: user))
      end

      assert_css(".tag-change-notice")
      assert_text("This tag is being discussed")
    end

    # Fork: replaces upstream's "escape forum topic titles in pending bulk
    # update notices". The notice prints no topic title at all now: it links
    # each request by its number (a request filed while the forum is retired
    # has no topic, and a topic link is a 404 to all but the owner).
    should "link each pending request by its number and print no forum topic title" do
      user = create(:user)
      tag = create(:tag, name: "aaa")
      topic = create(:forum_topic, title: %{<img src=x onerror="alert(1)">})
      bur1 = create(:bulk_update_request, user: user, script: "create alias aaa -> bbb", forum_topic: topic)
      bur2 = create(:bulk_update_request, user: user, script: "create alias aaa -> ccc", forum_topic: topic)

      html = render_inline(TagChangeNoticeComponent.new(tag: tag, current_user: user)).to_html

      assert_no_css("img")
      assert_no_match(/onerror/, html)
      assert_css(".tag-change-notice a[href='/bulk_update_requests/#{bur1.id}']", text: "bulk update request ##{bur1.id}")
      assert_css(".tag-change-notice a[href='/bulk_update_requests/#{bur2.id}']", text: "bulk update request ##{bur2.id}")
      assert_no_css("a[href*='forum_']")
    end

    # Fork: a request with no forum topic -- every request, while the forum
    # is retired -- rendered (upstream grouped by topic and raised on nil),
    # so a gallery or wiki page naming its tag does not 500.
    should "render a pending request that has no forum topic" do
      user = create(:user)
      tag = create(:tag, name: "aaa")
      bur = create(:bulk_update_request, user: user, script: "create alias aaa -> bbb")
      bur.update_columns(forum_topic_id: nil, forum_post_id: nil) # rubocop:disable Rails/SkipsModelValidations

      render_inline(TagChangeNoticeComponent.new(tag: tag, current_user: user))

      assert_css(".tag-change-notice a[href='/bulk_update_requests/#{bur.id}']", text: "bulk update request ##{bur.id}")
    end
  end
end
