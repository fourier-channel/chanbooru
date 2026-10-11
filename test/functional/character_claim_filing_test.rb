# frozen_string_literal: true

require "test_helper"

# Filing and releasing a claim on an original character (OC ownership, ruled
# 2026-10-11), from the creator's own edit page, through the gallery's update
# route (PATCH creators/:slug with claim_character or release_character; no
# new routes). Only the person the claim is for files it: the page's verified
# Matrix identity AND its linked booru account, signed in -- never an admin
# standing in, never an API key.
class CharacterClaimFilingTest < ActionDispatch::IntegrationTest
  SABER = { "X-Fourier-Identity" => "@saber:41chan.net" }.freeze

  setup do
    CreatorPrefixes.reset!
    @saber = create(:user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net", user: @saber)
  end

  def file_claim(user, name, headers: SABER)
    put_auth creator_gallery_path(@gallery), user, params: { claim_character: name }, headers: headers
  end

  context "filing" do
    should "complete a bare name, approve a clean one at once, and say so" do
      file_claim(@saber, "maple")

      assert_redirected_to edit_creator_gallery_path(@gallery, anchor: "creator-characters")
      claim = CharacterClaim.sole
      assert_equal(["maple_(saber)", @gallery], [claim.tag_name, claim.creator_gallery])
      assert(claim.approved?)
      assert_match(/maple_\(saber\) is yours now/, flash[:notice])
    end

    should "leave a name with history pending, and say why" do
      as(@admin) { create(:post, tag_string: "maple_(saber)") }
      file_claim(@saber, "maple")

      assert(CharacterClaim.sole.pending?)
      assert_match(/An admin will review it: it is on 1 post/, flash[:notice])
    end

    should "say why a name is refused, and leave no claim and no tag behind" do
      file_claim(@saber, "maple_(bob)")

      assert_response :redirect
      assert_match(/Not filed: maple_\(bob\) names bob: claim maple_\(saber\)/, flash[:notice])
      assert_equal(0, CharacterClaim.count)
      assert_nil(Tag.find_by_name("maple_(bob)"))
      assert_nil(Tag.find_by_name("maple_(saber)"))
    end

    should "be refused without the identity, without a booru session, on an API key, to an admin, and on an unlinked page" do
      file_claim(@saber, "maple", headers: {})
      assert_response 403

      reset!
      put creator_gallery_path(@gallery), params: { claim_character: "maple" }, headers: SABER
      assert_response 403

      key = create(:api_key, user: @saber)
      put creator_gallery_path(@gallery, login: @saber.name, api_key: key.key), params: { claim_character: "maple" }, headers: SABER
      assert_response 403

      file_claim(@admin, "maple", headers: {})
      assert_response 403

      @gallery.update!(user: nil)
      file_claim(@saber, "maple")
      assert_response 403
      assert_match(/Link this page to your booru account/, response.body)

      assert_equal(0, CharacterClaim.count)
      assert_nil(Tag.find_by_name("maple_(saber)"))
    end
  end

  context "releasing" do
    setup do
      file_claim(@saber, "maple")
      @claim = CharacterClaim.sole
    end

    should "work for the owner, and say so" do
      put_auth creator_gallery_path(@gallery), @saber, params: { release_character: @claim.id }, headers: SABER

      assert(@claim.reload.released?)
      assert_match(/released maple_\(saber\)/i, flash[:notice])
    end

    should "be refused to anyone else, an admin included, and to the owner without the identity" do
      put_auth creator_gallery_path(@gallery), @admin, params: { release_character: @claim.id }
      assert_response 403

      put_auth creator_gallery_path(@gallery), @saber, params: { release_character: @claim.id }
      assert_response 403

      assert(@claim.reload.approved?)
    end

    should "not reach another gallery's claim" do
      other = CreatorGallery.create!(slug: "bob", matrix_id: "@bob:41chan.net", user: create(:user))
      theirs = CharacterClaim.create!(creator_gallery: other, tag_name: "pine_(bob)")

      put_auth creator_gallery_path(@gallery), @saber, params: { release_character: theirs.id }, headers: SABER

      assert_match(/not one of this page's approved claims/, flash[:notice])
      assert(theirs.reload.pending?)
    end
  end

  context "the edit page's Characters section" do
    should "offer the owner a claim field with their name fixed, and a Release button per approved claim" do
      file_claim(@saber, "maple")
      get_auth edit_creator_gallery_path(@gallery), @saber, headers: SABER

      assert_response :success
      assert_select "section#creator-characters input[name='claim_character']", count: 1
      assert_select "section#creator-characters", text: /_\(saber\)/
      assert_select "section#creator-characters li", text: /maple_\(saber\).*approved/m
      assert_select "section#creator-characters input[name='release_character'][value='#{CharacterClaim.sole.id}']", count: 1
    end

    should "show an admin the claims read-only, with the queue" do
      file_claim(@saber, "maple")
      get_auth edit_creator_gallery_path(@gallery), @admin

      assert_response :success
      assert_select "section#creator-characters li", text: /maple_\(saber\)/
      assert_select "section#creator-characters input[name='claim_character']", count: 0
      assert_select "section#creator-characters input[name='release_character']", count: 0
      assert_select "section#creator-characters a[href='#{admin_artist_claims_path(anchor: "character-claims")}']"
    end
  end
end
