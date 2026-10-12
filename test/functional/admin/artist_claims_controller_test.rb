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

  # Original characters share the queue (OC ownership, ruled 2026-10-11):
  # the same two routes with kind=character, a second table, and the claims
  # an admin decides counted in the same pill.
  context "original character claims" do
    setup do
      as(@admin) { create(:post, tag_string: "pine_(maple)") }
      @character = CharacterClaim.prepare(@gallery, @maple, "pine").first
      @character.file!
    end

    should "be listed in their own table, pending first, with the rule as it stands" do
      get_auth admin_artist_claims_path, @admin

      assert_response :success
      assert_select "#character-claims tr#character-claim-#{@character.id}", text: /pine_\(maple\).*pending.*rule holds/m
      assert_select "#character-claims tr#character-claim-#{@character.id} .character-claim-waits", text: "waits because it is on 1 post"
      assert_select "#character-claims tr#character-claim-#{@character.id} form[action='#{approve_admin_artist_claim_path(@character, kind: "character")}']", count: 1
    end

    should "be approved and rejected with kind=character, leaving artist claims alone" do
      post_auth approve_admin_artist_claim_path(@character), @admin, params: { kind: "character" }

      assert_redirected_to admin_artist_claims_path(anchor: "character-claims")
      assert(@character.reload.approved?)
      assert(@claim.reload.pending?)
      assert_match(/pine_\(maple\)/, flash[:notice])

      post_auth reject_admin_artist_claim_path(@character), @admin, params: { kind: "character", note: "approval withdrawn" }
      assert(@character.reload.rejected?)
      assert_equal("approval withdrawn", @character.note)
    end

    should "scroll each table inside its own box, so a phone does not scroll the page" do
      get_auth admin_artist_claims_path, @admin

      %w[artist-claims artist-claims-decided character-claims].each do |id|
        assert_select ".overflow-auto > table##{id}", count: 1
      end
    end

    should "flag a decided claim that no longer stands" do
      @character.approve!(by: @admin)
      create(:tag_alias, antecedent_name: "pine_(maple)", consequent_name: "pine_tree")

      get_auth admin_artist_claims_path, @admin
      assert_select "#character-claims tr#character-claim-#{@character.id}", text: /aliased to pine_tree/
    end

    should "be forbidden to a moderator" do
      post_auth approve_admin_artist_claim_path(@character), @moderator, params: { kind: "character" }

      assert_response 403
      assert(@character.reload.pending?)
    end

    should "answer any other kind with a 400 that names the allowed ones" do
      post_auth approve_admin_artist_claim_path(@character), @admin, params: { kind: "bogus" }

      assert_response 400
      assert_includes(response.body, "kind must be character or absent")
      assert(@character.reload.pending?)
    end

    should "count in the Claims pill" do
      get_auth posts_path(preset: "modulation"), @admin
      assert_select "#top.modnav a.modnav-pill[href='#{admin_artist_claims_path}']", text: /Claims\s*2/, count: 1
    end

    # Ownership a legacy tag's move assigned to a creator with no page yet
    # (CharacterClaim::HELD, 2026-10-12): listed with the name it waits for,
    # not counted as waiting for an admin, and withdrawable before the page.
    should "list a claim held for a creator with no page, and let an admin withdraw it" do
      as(@admin) { create(:post, tag_string: "oc_kayla") }
      as(@admin) { TagAlias.approve!(antecedent_name: "oc_kayla", consequent_name: "kayla_(selphdestruct)", approver: @admin) }
      held = CharacterClaim.held.find_by!(tag_name: "kayla_(selphdestruct)")

      get_auth admin_artist_claims_path, @admin
      assert_response :success
      assert_select "#character-claims tr#character-claim-#{held.id}", text: /kayla_\(selphdestruct\).*@selphdestruct.*no creator page yet.*held by #{@admin.name}/m
      assert_select "#character-claims tr#character-claim-#{held.id} form[action='#{reject_admin_artist_claim_path(held, kind: "character")}']", count: 1

      post_auth reject_admin_artist_claim_path(held), @admin, params: { kind: "character", note: "wrong creator" }
      assert_redirected_to admin_artist_claims_path(anchor: "character-claims")
      assert_match(/@selphdestruct's claim on kayla_\(selphdestruct\)/, flash[:notice])
      assert_equal([CharacterClaim::REJECTED, nil], held.reload.slice(:status, :creator_gallery_id).values)
      assert_match(/withdrew @selphdestruct's held claim on original character kayla_\(selphdestruct\): wrong creator/, ModAction.last.description)

      CreatorGallery.create!(slug: "selphdestruct", matrix_id: "@selphdestruct:41chan.net")
      assert(held.reload.rejected?, "a withdrawn hold is not taken up by the gallery")
    end
  end
end
