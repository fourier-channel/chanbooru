# frozen_string_literal: true

require "test_helper"

# A claimed original character's wiki page is its creator's (operator ruling
# 2026-10-11, Q3: exclusive, the owner and admins only). The owner edits as
# their linked booru account, with no Matrix header: identity was proven once,
# when the claim was filed. Everyone else gets a 403 that says whose it is.
class CharacterClaimWikiTest < ActionDispatch::IntegrationTest
  DENIAL = "maple_(saber)'s wiki belongs to its creator, @saber. Only they or an admin can edit it."

  setup do
    CreatorPrefixes.reset!
    @saber = create(:user)
    @member = create(:user)
    @builder = create(:builder_user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net", user: @saber)
    @claim = CharacterClaim.prepare(@gallery, @saber, "maple").first
    @claim.file!
  end

  def edit_as(user, attributes = { body: "edited by #{user.name}" })
    put_auth wiki_page_path(@wiki), user, params: { wiki_page: attributes }
  end

  context "a claimed title with no page yet" do
    should "be created by its owner and nobody else but an admin" do
      post_auth wiki_pages_path, @member, params: { wiki_page: { title: "maple_(saber)", body: "not mine" }}
      assert_response 403
      assert_includes(CGI.unescapeHTML(response.body), DENIAL)
      assert_nil(WikiPage.find_by(title: "maple_(saber)"))

      post_auth wiki_pages_path, @saber, params: { wiki_page: { title: "maple_(saber)", body: "mine" }}
      assert_equal("mine", WikiPage.find_by!(title: "maple_(saber)").body)
    end

    should "still render the new-page form and show_or_new, which ask the policy with the class" do
      get_auth new_wiki_page_path, @member
      assert_response :success

      get_auth show_or_new_wiki_pages_path(title: "maple_(saber)"), @member
      assert_redirected_to wiki_page_path("maple_(saber)")

      get_auth wiki_page_path("maple_(saber)"), @member
      assert_response 404
      assert_select "a", text: "Create new wiki page", count: 0
    end
  end

  context "a claimed page" do
    setup do
      @wiki = as(@saber) { create(:wiki_page, title: "maple_(saber)", body: "mine") }
    end

    should "let its owner edit, revert and delete it without a Matrix header" do
      travel(1.day) # a later edit is a new version, not a merge into the first
      edit_as(@saber)
      assert_equal("edited by #{@saber.name}", @wiki.reload.body)

      put_auth revert_wiki_page_path(@wiki), @saber, params: { version_id: @wiki.versions.order(:id).first.id }
      assert_equal("mine", @wiki.reload.body)

      delete_auth wiki_page_path(@wiki), @saber
      assert(@wiki.reload.is_deleted?)
    end

    should "refuse a member, a builder and a moderator, saying whose it is" do
      [@member, @builder, create(:moderator_user)].each do |user|
        edit_as(user)
        assert_response 403, user.name
        assert_includes(CGI.unescapeHTML(response.body), DENIAL, user.name)
      end
      assert_equal("mine", @wiki.reload.body)
    end

    should "refuse a builder on a locked page, and not stop its owner" do
      as(@admin) { @wiki.update!(is_locked: true) }

      edit_as(@builder)
      assert_response 403
      edit_as(@saber)
      assert_equal("edited by #{@saber.name}", @wiki.reload.body)
    end

    should "let an admin edit it" do
      edit_as(@admin)
      assert_equal("edited by #{@admin.name}", @wiki.reload.body)
    end

    should "let only an admin rename it away" do
      edit_as(@saber, title: "elsewhere")
      assert_response 403
      assert_equal("maple_(saber)", @wiki.reload.title)
    end

    should "tell the owner renaming it that only an admin moves a claimed page" do
      edit_as(@saber, title: "elsewhere")

      assert_response 403
      assert_includes(CGI.unescapeHTML(response.body), "Only an admin moves a page onto or off a claimed character's title (maple_(saber))")
      assert_not_includes(CGI.unescapeHTML(response.body), DENIAL)
    end

    should "put the refusal's reason above the flowchart, once, naming the creator page only where it shows a contact" do
      edit_as(@member)

      assert_response 403
      assert_select ".oh-no-title + .oh-no-reason", text: /#{Regexp.escape(DENIAL)} To suggest a change, ask an admin\./
      assert_select ".oh-no-reason", text: /#{Regexp.escape(creator_gallery_path(@gallery))}/, count: 0
      assert_select ".oh-no-details", text: /belongs to its creator/, count: 0

      @gallery.update!(show_contact: true)
      edit_as(@member)

      assert_response 403
      assert_select ".oh-no-title + .oh-no-reason", text: /#{Regexp.escape(DENIAL)}.*#{Regexp.escape(creator_gallery_path(@gallery))}/
    end

    should "refuse another page renamed onto it" do
      other = as(@member) { create(:wiki_page, title: "some_other_page") }
      put_auth wiki_page_path(other), @member, params: { wiki_page: { title: "maple_(saber)" }}

      assert_response 403
      assert_equal("some_other_page", other.reload.title)
    end

    should "refuse a banned owner and an unlinked owner" do
      @gallery.update!(user: nil)
      edit_as(@saber)
      assert_response 403

      @gallery.update!(user: @saber)
      as(@admin) { create(:ban, user: @saber, banner: @admin) }
      edit_as(@saber)
      assert_response 403
      assert_equal("mine", @wiki.reload.body)
    end

    should "open to members again once the claim is withdrawn" do
      @claim.reject!(by: @admin, note: "approval withdrawn")

      edit_as(@member)
      assert_equal("edited by #{@member.name}", @wiki.reload.body)
    end

    should "carry the 'Original character of' line, and hide Edit from a non-owner" do
      get_auth wiki_page_path(@wiki), @member
      assert_response :success
      assert_select "#wiki-page-original-character", text: /Original character of @saber/
      assert_select "#wiki-page-original-character a[href='#{creator_gallery_path(@gallery)}']"
      assert_select "#wiki-page-original-character", text: /kept by its creator/
      assert_select "a[href='#{edit_wiki_page_path(@wiki.id)}']", count: 0

      get_auth wiki_page_path(@wiki), @saber
      assert_select "a[href='#{edit_wiki_page_path(@wiki.id)}']", minimum: 1
    end
  end

  # A revert sets the page's title to the version's (WikiPage#revert_to), so
  # it is asked as the edit it is: title and the title it had.
  context "a revert" do
    should "not move an unclaimed page onto a claimed title" do
      wiki = as(@admin) { create(:wiki_page, title: "maple_(saber)", body: "vandal text") }
      travel(1.day)
      as(@admin) { wiki.update!(title: "maple_draft") }

      put_auth revert_wiki_page_path(wiki), @member, params: { version_id: wiki.versions.order(:id).first.id }

      assert_response 403
      assert_equal("maple_draft", wiki.reload.title)
    end

    should "not let the owner move the claimed page away" do
      wiki = as(@admin) { create(:wiki_page, title: "maple_old", body: "old") }
      travel(1.day)
      as(@admin) { wiki.update!(title: "maple_(saber)") }

      put_auth revert_wiki_page_path(wiki), @saber, params: { version_id: wiki.versions.order(:id).first.id }

      assert_response 403
      assert_includes(CGI.unescapeHTML(response.body), "Only an admin moves a page onto or off a claimed character's title")
      assert_equal("maple_(saber)", wiki.reload.title)
    end

    should "refuse a member on a locked unclaimed page, as upstream" do
      wiki = as(@admin) { create(:wiki_page, title: "pine_tree", body: "one") }
      travel(1.day)
      as(@admin) { wiki.update!(body: "two", is_locked: true) }

      put_auth revert_wiki_page_path(wiki), @member, params: { version_id: wiki.versions.order(:id).first.id }

      assert_response 403
      assert_equal("two", wiki.reload.body)
    end
  end

  context "an unclaimed page" do
    should "behave exactly as upstream, with no line" do
      @wiki = as(@member) { create(:wiki_page, title: "pine_(saber)", body: "anyone's") }

      edit_as(@member)
      assert_equal("edited by #{@member.name}", @wiki.reload.body)

      get_auth wiki_page_path(@wiki), @member
      assert_select "#wiki-page-original-character", count: 0
    end
  end
end
