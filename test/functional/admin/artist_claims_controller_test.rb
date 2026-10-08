# frozen_string_literal: true

require "test_helper"

# The creator-claim queue. Admins approve (design CREATOR_VISIBILITY Q6, ruled
# 2026-10-07): a claim keys a creator's control over who sees their posts, and
# moderators -- who issue TagGrants and see nothing a creator hid (Q2) -- must
# not be able to hand that out, to anyone or to themselves.
class Admin::ArtistClaimsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin_user)
    @moderator = create(:moderator_user)
    @member = create(:user)
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple)
    @artist = as(@admin) { create(:artist, name: "4chan_maple") }
    @claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
  end

  context "the queue" do
    should "be forbidden to a signed-out visitor, a member and a moderator" do
      get admin_artist_claims_path
      assert_response 403

      [@member, @moderator].each do |user|
        get_auth admin_artist_claims_path, user
        assert_response 403, user.name
      end
    end

    should "list pending claims for an admin, with who filed them" do
      get_auth admin_artist_claims_path, @admin

      assert_response :success
      assert_select "#artist-claims tr#artist-claim-#{@claim.id}", text: /4chan_maple/
      assert_select "#artist-claims tr#artist-claim-#{@claim.id}", text: /@maple:41chan\.net/
      assert_select "#artist-claims tr#artist-claim-#{@claim.id} form[action='#{approve_admin_artist_claim_path(@claim)}']", count: 1
    end
  end

  context "approving" do
    should "be forbidden to a moderator, and change nothing" do
      post_auth approve_admin_artist_claim_path(@claim), @moderator

      assert_response 403
      assert(@claim.reload.pending?)
      assert_equal 0, ModAction.count
    end

    should "approve and log for an admin" do
      post_auth approve_admin_artist_claim_path(@claim), @admin

      assert_redirected_to admin_artist_claims_path
      assert(@claim.reload.approved?)
      assert_equal(@admin, @claim.approver)
      assert_equal("artist_claim_approve", ModAction.sole.category)
      assert_match(/4chan_maple/, flash[:notice])
    end

    should "say why when the rule no longer holds, and leave the claim pending" do
      rival = CreatorGallery.create!(slug: "rival", matrix_id: "@maple:other.example", user: create(:user))
      ArtistClaim.create!(artist: @artist, creator_gallery: rival).approve!(by: @admin)

      post_auth approve_admin_artist_claim_path(@claim), @admin

      assert_redirected_to admin_artist_claims_path
      assert_match(/already has an approved claim/, flash[:notice])
      assert(@claim.reload.pending?)
    end

    # The validations name every clash the unique indexes guard, but two
    # admins approving at once still meet at the index: that is an answer for
    # the admin, not a 500.
    should "answer a clash at the database index with a notice, not an error page" do
      ArtistClaim.any_instance.stubs(:approve!).raises(ActiveRecord::RecordNotUnique, "duplicate key")

      post_auth approve_admin_artist_claim_path(@claim), @admin

      assert_redirected_to admin_artist_claims_path
      assert_match(/Not approved.*approved claim/, flash[:notice])
      assert(@claim.reload.pending?)
    end
  end

  context "rejecting" do
    should "be forbidden to a moderator" do
      post_auth reject_admin_artist_claim_path(@claim), @moderator, params: { note: "no" }

      assert_response 403
      assert(@claim.reload.pending?)
    end

    should "reject with the admin's note, and log it" do
      post_auth reject_admin_artist_claim_path(@claim), @admin, params: { note: "not the same person" }

      assert_redirected_to admin_artist_claims_path
      assert(@claim.reload.rejected?)
      assert_equal("not the same person", @claim.note)
      assert_equal("artist_claim_reject", ModAction.sole.category)
    end
  end

  context "the way in" do
    should "be in the site map's Admin block for an admin only" do
      get_auth site_map_path, @admin
      assert_select "a[href='#{admin_artist_claims_path}']", count: 1

      get_auth site_map_path, @moderator
      assert_select "a[href='#{admin_artist_claims_path}']", count: 0
    end

    should "be a Claims pill with the pending count for an admin, and absent for a moderator" do
      get_auth posts_path(preset: "modulation"), @admin
      assert_response :success
      assert_select "#top.modnav a.modnav-pill[href='#{admin_artist_claims_path}']", text: /Claims\s*1/, count: 1

      get_auth posts_path(preset: "modulation"), @moderator
      assert_select "#top.modnav .modnav-pill", text: /Claims/, count: 0
    end

    should "leave the pill out when nothing is waiting" do
      @claim.reject!(by: @admin)

      get_auth posts_path(preset: "modulation"), @admin
      assert_select "#top.modnav .modnav-pill", text: /Claims/, count: 0
    end
  end
end
