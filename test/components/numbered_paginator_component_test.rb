require "test_helper"

class NumberedPaginatorComponentTest < ViewComponent::TestCase
  context "The NumberedPaginatorComponent" do
    should "render numbered pagination links" do
      create_list(:tag, 10)
      # Fork: a full account; outside a request paginate has no CurrentUser to ask.
      records = Tag.all.paginate(2, limit: 3, page_limit: 100, viewer: build(:user))
      params = ActionController::Parameters.new(controller: "tags", action: "index")

      render_inline(NumberedPaginatorComponent.new(records: records, params: params))

      assert_css(".numbered-paginator")
      assert_css("a.paginator-prev[rel='prev']")
      assert_css("a.paginator-next[rel='next']")
    end

    # The last page a full account may reach goes on by cursor: next_page is
    # the String "b<id>" there, which the page-limit comparison must not meet.
    should "render the last page a full account may reach, its next a cursor" do
      create_list(:tag, 7)
      records = Tag.order(id: :desc).paginate(3, limit: 2, page_limit: 3, viewer: build(:user))
      params = ActionController::Parameters.new(controller: "tags", action: "index")

      render_inline(NumberedPaginatorComponent.new(records: records, params: params))

      assert_css("a.paginator-next[href*='page=b']:not([hidden])")
      assert_css("a.paginator-prev[href*='page=2']")
    end

    should "draw a viewer below full browsing no page past the first" do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(2)
      create_list(:tag, 7)
      records = Tag.order(id: :desc).paginate(1, limit: 2, viewer: create(:restricted_user))
      params = ActionController::Parameters.new(controller: "tags", action: "index")

      render_inline(NumberedPaginatorComponent.new(records: records, params: params))

      assert_no_css("a.paginator-next")
      assert_no_css("a.paginator-page:not([hidden])")
    end
  end
end
