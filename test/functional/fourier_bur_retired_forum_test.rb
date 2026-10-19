require "test_helper"

# Fork: while the forum is retired (operator ruling 2026-09-06,
# FourierRetiredSections), a bulk update request opens no forum topic, keeps
# its reason on itself, and every link it answers with goes to the request --
# a forum link is a 404 to everyone but the owner. The test env retires
# nothing, so the forum is switched off here, as production has it.
class FourierBurRetiredForumTest < ActionDispatch::IntegrationTest
  setup do
    Danbooru.config.stubs(:retired_sections).returns(%w[forum_topics forum_posts forum_post_votes forum_topic_visits])
    @member = create(:user)
  end

  should "redirect a create from the page to the request, and the redirect resolves" do
    post_auth bulk_update_requests_path, @member, params: { bulk_update_request: { script: "create alias aaa -> bbb", title: "t", reason: "because" }}

    bur = BulkUpdateRequest.last
    assert_redirected_to bulk_update_request_path(bur)
    follow_redirect!
    assert_response :success
  end

  should "answer a JSON create 201 whose Location is the request, with the reason and no forum" do
    assert_no_difference(["ForumTopic.count", "ForumPost.count"]) do
      post_auth bulk_update_requests_path(format: :json), @member, params: { bulk_update_request: { script: "create alias aaa -> bbb", reason: "because" }}
    end

    assert_response 201
    bur = BulkUpdateRequest.last
    assert_equal(bulk_update_request_url(bur), response.headers["Location"])
    body = response.parsed_body
    assert_equal("because", body["reason"])
    assert_equal([true, nil, nil], [body.key?("forum_topic_id"), body["forum_topic_id"], body["forum_post_id"]])

    get_auth "#{response.headers["Location"]}.json", @member
    assert_response :success
    assert_equal("because", response.parsed_body["reason"])
  end

  should "refuse a forum topic with 422, a sentence that says what to do, and no lines" do
    topic = as(create(:admin_user)) { create(:forum_topic) }

    assert_no_difference(["BulkUpdateRequest.count", "ForumPost.count"]) do
      post_auth bulk_update_requests_path(format: :json), @member, params: { bulk_update_request: { script: "create alias aaa -> bbb", reason: "r", forum_topic_id: topic.id }}
    end

    assert_response 422
    body = response.parsed_body
    assert_equal("BulkUpdateRequest::Processor::Error", body["error"])
    assert_equal("Forum topics are retired on this site, so a request cannot be attached to one. Send the request without forum_topic_id or forum_post_id", body["message"])
    assert_equal([], body["errors"])
  end

  should "not promise a forum topic on the new form, and take the reason as plain text" do
    get_auth new_bulk_update_request_path, @member

    assert_response :success
    assert_select "input[name='bulk_update_request[title]']", 0
    assert_no_match(/forum topic/i, css_select("form").text)
    assert_select "textarea[name='bulk_update_request[reason]']", 1
    assert_select "form .dtext-editor", 0
  end

  should "show the reason as plain text on the request page, and link into the forum from neither the page nor the listing" do
    admin = create(:admin_user)
    topic = as(admin) { create(:forum_topic) }
    forum_post = as(admin) { create(:forum_post, topic: topic) }
    bur = as(@member) { create(:bulk_update_request, user: @member, reason: "see [b]this[/b] <i>now</i>") }
    # A request filed before the forum was retired keeps its topic.
    bur.update_columns(forum_topic_id: topic.id, forum_post_id: forum_post.id) # rubocop:disable Rails/SkipsModelValidations

    get_auth bulk_update_request_path(bur), @member
    assert_response :success
    assert_select "#bulk-update-request-reason", text: "see [b]this[/b] <i>now</i>"
    assert_select "#bulk-update-request-reason b, #bulk-update-request-reason i", 0
    assert_select "#c-bulk-update-requests a[href*='forum_']", 0

    get bulk_update_requests_path
    assert_response :success
    assert_select "#c-bulk-update-requests a[href='#{bulk_update_request_path(bur)}']"
    assert_select "#c-bulk-update-requests a[href*='forum_']", 0
  end

  should "not serve a request's forum topic or post through ?only=" do
    admin = create(:admin_user)
    topic = as(admin) { create(:forum_topic) }
    forum_post = as(admin) { create(:forum_post, topic: topic, body: "words from the retired forum") }
    bur = as(@member) { create(:bulk_update_request, user: @member) }
    # A request filed before the forum was retired keeps its topic.
    bur.update_columns(forum_topic_id: topic.id, forum_post_id: forum_post.id) # rubocop:disable Rails/SkipsModelValidations

    get_auth bulk_update_request_path(bur, format: :json, only: "id,forum_post[body],forum_topic[title]"), @member

    assert_response :success
    assert_equal({ "id" => bur.id }, response.parsed_body)
  end
end
