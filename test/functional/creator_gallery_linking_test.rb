# frozen_string_literal: true

require "test_helper"

# Which booru account a creator gallery belongs to (design CREATOR_VISIBILITY
# section 9, ruled 2026-10-07). creator_galleries.user_id is the only stored
# link from a Matrix identity to a booru account, and creator control reads it:
# whoever it names controls the creator's posts. So it is set only from a
# VERIFIED match -- never to an admin who made the page for someone else -- and
# an owner who was not signed in to the booru when the page was made links it
# afterwards, explicitly, under both sessions at once. Linking rides the
# gallery's own update route (PATCH creators/:slug), as the routes ruling of
# 2026-09-24 asks.
class CreatorGalleryLinkingTest < ActionDispatch::IntegrationTest
  DAVE = { "X-Fourier-Identity" => "@dave:41chan.net" }.freeze

  def link(user, headers: {}, params: {})
    put_auth creator_gallery_path(@gallery), user, params: { link_account: "1", **params }, headers: headers
  end

  def link_form_count
    css_select("form[action='#{creator_gallery_path(@gallery)}'] input[name='link_account']").size
  end

  context "making a gallery" do
    should "never store the admin's account on a gallery made for another Matrix id" do
      admin = create(:admin_user)
      post_auth creator_galleries_path, admin, params: { creator_gallery: { matrix_id: "@bob:41chan.net", title: "Bob" }}

      gallery = CreatorGallery.find_by!(matrix_id: "@bob:41chan.net")
      assert_nil(gallery.user_id)
    end

    should "link the signed-in account of the verified owner" do
      carol = create(:user)
      post_auth creator_galleries_path, carol, params: { creator_gallery: { title: "Carol" }},
                                               headers: { "X-Fourier-Identity" => "@carol:41chan.net" }

      assert_equal(carol.id, CreatorGallery.find_by!(matrix_id: "@carol:41chan.net").user_id)
    end

    should "link nobody for an owner not signed in to the booru" do
      post creator_galleries_path, params: { creator_gallery: { title: "Erin" }}, headers: { "X-Fourier-Identity" => "@erin:41chan.net" }

      assert_nil(CreatorGallery.find_by!(matrix_id: "@erin:41chan.net").user_id)
    end

    # The Matrix identity comes from the browser's fourier_session cookie; an
    # API-key request skips CSRF protection. Together they would let a page on
    # any 41chan.net subdomain join the visitor's Matrix identity to the
    # attacker's booru account.
    should "not take the verified identity on an API-key request" do
      attacker = create(:user)
      key = create(:api_key, user: attacker)
      url = creator_galleries_path(login: attacker.name, api_key: key.key)
      post url, params: { creator_gallery: { title: "Erin" }}, headers: { "X-Fourier-Identity" => "@erin:41chan.net" }

      assert_response 403
      assert_nil(CreatorGallery.find_by(matrix_id: "@erin:41chan.net"))
    end
  end

  context "linking an unlinked gallery" do
    setup do
      @dave = create(:user)
      @gallery = CreatorGallery.create!(slug: "dave", matrix_id: "@dave:41chan.net")
    end

    should "be offered on the edit page to the verified owner who is signed in" do
      get_auth edit_creator_gallery_path(@gallery), @dave, headers: DAVE

      assert_response :success
      assert_equal(1, link_form_count)
    end

    should "link it to the owner's account" do
      link(@dave, headers: DAVE)

      assert_redirected_to edit_creator_gallery_path(@gallery)
      assert_equal(@dave.id, @gallery.reload.user_id)
    end

    should "be forbidden without the verified identity, signed out, or under another identity" do
      link(@dave)
      assert_response 403

      link(@dave, headers: { "X-Fourier-Identity" => "@mallory:41chan.net" })
      assert_response 403

      reset!
      put creator_gallery_path(@gallery), params: { link_account: "1" }, headers: DAVE
      assert_response 403

      assert_nil(@gallery.reload.user_id)
    end

    # An admin can edit any gallery, but cannot become its creator.
    should "be forbidden to an admin acting without the owner's identity" do
      link(create(:admin_user))

      assert_response 403
      assert_nil(@gallery.reload.user_id)
    end

    # Linking is what hands an account control of the creator's posts; a
    # banned account is refused it as it is refused a claim.
    should "be forbidden to a banned account, and not offered to it" do
      banned = create(:banned_user)
      get_auth edit_creator_gallery_path(@gallery), banned, headers: DAVE
      assert_equal(0, link_form_count)

      link(banned, headers: DAVE)
      assert_response 403
      assert_nil(@gallery.reload.user_id)
    end

    should "be forbidden on an API-key request, whatever identity the cookie carries" do
      attacker = create(:user)
      key = create(:api_key, user: attacker)
      put creator_gallery_path(@gallery, login: attacker.name, api_key: key.key), params: { link_account: "1" }, headers: DAVE

      assert_response 403
      assert_nil(@gallery.reload.user_id)
    end
  end

  context "a gallery already linked" do
    setup do
      @dave = create(:user)
      @other = create(:user)
      @admin = create(:admin_user)
      @gallery = CreatorGallery.create!(slug: "dave", matrix_id: "@dave:41chan.net", user: @other)
    end

    # Rewriting a link is a decision about whose posts these are; it is not
    # the signed-in account's to take over by asking.
    should "not be re-linked to another account, and say what to do instead" do
      link(@dave, headers: DAVE)

      assert_redirected_to edit_creator_gallery_path(@gallery)
      assert_match(/already linked.*admin.*unlink/i, flash[:notice])
      assert_equal(@other.id, @gallery.reload.user_id)
    end

    should "not offer the link on the edit page" do
      get_auth edit_creator_gallery_path(@gallery), @dave, headers: DAVE

      assert_equal(0, link_form_count)
    end

    # The remedy the refusal above names: an admin clears the link, logged for
    # admins, and the owner then links their own account.
    should "be unlinked by an admin, logged for admins only, and then linkable by its owner" do
      get_auth edit_creator_gallery_path(@gallery), @admin
      assert_select "form[action='#{creator_gallery_path(@gallery)}'] input[name='unlink_account']", count: 1

      put_auth creator_gallery_path(@gallery), @admin, params: { unlink_account: "1" }
      assert_redirected_to edit_creator_gallery_path(@gallery)
      assert_nil(@gallery.reload.user_id)

      action = ModAction.sole
      assert_equal(["creator_gallery_unlink", @admin], [action.category, action.creator])
      assert_includes(action.description, "@dave:41chan.net")
      assert_not_includes(ModAction.visible(create(:moderator_user)), action)

      link(@dave, headers: DAVE)
      assert_equal(@dave.id, @gallery.reload.user_id)
    end

    should "not be unlinked by its owner, a moderator or the linked account" do
      [[@dave, DAVE], [create(:moderator_user), {}], [@other, DAVE]].each do |user, headers|
        get_auth edit_creator_gallery_path(@gallery), user, headers: headers
        assert_select "input[name='unlink_account']", count: 0

        put_auth creator_gallery_path(@gallery), user, params: { unlink_account: "1" }, headers: headers
        assert_response 403, user.name
      end

      assert_equal(@other.id, @gallery.reload.user_id)
      assert_equal(0, ModAction.count)
    end
  end
end
