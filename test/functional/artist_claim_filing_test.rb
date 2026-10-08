# frozen_string_literal: true

require "test_helper"

# Filing a claim on a creator tag (design CREATOR_VISIBILITY section 9, ruled
# 2026-10-07). Only the person the claim would be FOR can file it: signed in to
# the booru, carrying the verified Matrix identity of a gallery linked to that
# same booru account. Offered from the artist page and from the gallery's own
# edit page, and offered only where it could succeed -- one check
# (ArtistClaim.prepare) decides both, so the button and the refusal cannot
# disagree. Filing rides the gallery's own update route (PATCH creators/:slug),
# as the routes ruling of 2026-09-24 asks.
class ArtistClaimFilingTest < ActionDispatch::IntegrationTest
  MAPLE = { "X-Fourier-Identity" => "@maple:41chan.net" }.freeze

  setup do
    @maple = create(:user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple)
    @artist = as(@admin) { create(:artist, name: "4chan_maple") }
    # A creator tag with posts and no Artist entry: the tunnel files creator
    # tags as artist tags and makes no entry for them.
    as(@admin) { create(:tag, name: "aichan_maple", category: TagCategory::ARTIST) }
  end

  def file_claim(user, tag_name, headers: MAPLE)
    put_auth creator_gallery_path(@gallery), user, params: { claim_tag: tag_name }, headers: headers
  end

  def claim_link_count(artist, user, headers: {}, gallery: @gallery)
    get_auth artist_path(artist), user, headers: headers
    assert_response :success
    css_select("a[href='#{creator_gallery_path(gallery, claim_tag: artist.name)}']").size
  end

  context "the artist page" do
    should "offer 'Claim this creator' to the verified, linked owner" do
      assert_equal 1, claim_link_count(@artist, @maple, headers: MAPLE)
      assert_select "a[data-method='patch']", text: "Claim this creator"
    end

    should "not offer it without the verified identity, to another account, or for someone else's tag" do
      assert_equal 0, claim_link_count(@artist, @maple)
      assert_equal 0, claim_link_count(@artist, create(:user), headers: MAPLE)
      assert_equal 0, claim_link_count(as(@admin) { create(:artist, name: "4chan_rival") }, @maple, headers: MAPLE)
    end

    should "not offer it for the master tag, which needs no claim, or once a claim is waiting" do
      assert_equal 0, claim_link_count(as(@admin) { create(:artist, name: "41chan_maple") }, @maple, headers: MAPLE)

      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
      assert_equal 0, claim_link_count(@artist, @maple, headers: MAPLE)
    end

    should "not offer it to a banned account" do
      banned = create(:banned_user)
      gallery = CreatorGallery.create!(slug: "banned", matrix_id: "@maplebanned:41chan.net", user: banned)
      artist = as(@admin) { create(:artist, name: "4chan_maplebanned") }

      assert_equal 0, claim_link_count(artist, banned, headers: { "X-Fourier-Identity" => "@maplebanned:41chan.net" }, gallery: gallery)
    end

    # Any member can rename an Artist. An entry renamed under someone else's
    # approved claim still carries it, and a second approval on one entry is
    # refused, so the claim is not offered there: it could never succeed.
    should "not offer it on an entry renamed from another creator's approved claim" do
      other = CreatorGallery.create!(slug: "bob", matrix_id: "@bob:41chan.net", user: create(:user))
      bobs = as(@admin) { create(:artist, name: "4chan_bob") }
      ArtistClaim.create!(artist: bobs, creator_gallery: other).approve!(by: @admin)
      as(@admin) do
        @artist.update!(name: "4chan_maple_old")
        bobs.update!(name: "4chan_maple")
      end

      assert_equal 0, claim_link_count(bobs, @maple, headers: MAPLE)
      file_claim(@maple, "4chan_maple")
      assert_match(/approved claim on 4chan_bob/, flash[:notice])
      assert_equal 1, ArtistClaim.count
    end

    should "file a pending claim keyed on the tag" do
      file_claim(@maple, "4chan_maple")

      assert_response :redirect
      claim = ArtistClaim.sole
      assert_equal(["4chan_maple", @artist, @gallery], [claim.tag_name, claim.artist, claim.creator_gallery])
      assert(claim.pending?)
      assert_match(/an admin/i, flash[:notice])
    end
  end

  context "the gallery's edit page" do
    should "list the creator tags its owner could claim, with a button for each" do
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE

      assert_response :success
      assert_select "#creator-claims form[action='#{creator_gallery_path(@gallery)}'] input[name='claim_tag']", count: 2
      assert_select "#creator-claims input[name='claim_tag'][value='4chan_maple']", count: 1
      assert_select "#creator-claims input[name='claim_tag'][value='aichan_maple']", count: 1
    end

    should "show a claim already filed by its status instead of a button" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE

      assert_select "#creator-claims input[name='claim_tag'][value='4chan_maple']", count: 0
      assert_select "#creator-claims", text: /4chan_maple.*pending/m
    end

    # A tag that exists as a general tag with posts cannot get an Artist
    # entry, so a claim on it cannot be filed -- and is not offered.
    should "not offer a tag no Artist entry could be made for" do
      as(@admin) { Tag.find_by_name("aichan_maple").update!(category: TagCategory::GENERAL, post_count: 3, updater: @admin) }
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE

      assert_select "#creator-claims input[name='claim_tag'][value='aichan_maple']", count: 0
      assert_select "#creator-claims input[name='claim_tag'][value='4chan_maple']", count: 1
    end

    should "make the Artist entry when the tag has none, the way /artists does" do
      file_claim(@maple, "aichan_maple")

      artist = Artist.find_by!(name: "aichan_maple")
      assert_equal(artist, ArtistClaim.sole.artist)
      assert_equal(@maple.id, artist.versions.sole.updater_id)
    end
  end

  context "a refused filing" do
    should "be forbidden without the verified identity, signed out, or from another account" do
      file_claim(@maple, "4chan_maple", headers: {})
      assert_response 403

      reset!
      put creator_gallery_path(@gallery), params: { claim_tag: "4chan_maple" }, headers: MAPLE
      assert_response 403

      file_claim(create(:user), "4chan_maple")
      assert_response 403

      file_claim(@maple, "4chan_maple", headers: { "X-Fourier-Identity" => "@rival:41chan.net" })
      assert_response 403

      assert_equal 0, ArtistClaim.count
    end

    # An admin who made the gallery is not its claimant: the claim is the
    # creator's word, under the creator's verified session.
    should "be forbidden to an admin acting for the creator" do
      file_claim(@admin, "4chan_maple", headers: {})

      assert_response 403
      assert_equal 0, ArtistClaim.count
    end

    should "be forbidden to a banned account" do
      as(@admin) { create(:ban, user: @maple, banner: @admin) }
      file_claim(@maple, "4chan_maple")

      assert_response 403
      assert_equal 0, ArtistClaim.count
    end

    # The identity header comes from the browser's cookie; an API-key request
    # skips CSRF protection, so it never stands in for the claimant's session.
    should "be forbidden on an API-key request" do
      key = create(:api_key, user: @maple)
      put creator_gallery_path(@gallery, login: @maple.name, api_key: key.key), params: { claim_tag: "4chan_maple" }, headers: MAPLE

      assert_response 403
      assert_equal 0, ArtistClaim.count
    end

    should "say why, and leave no claim and no stray Artist, for a tag the rule refuses" do
      file_claim(@maple, "aichan_rival")

      assert_response :redirect
      assert_match(/identical to the claimant's Matrix name/, flash[:notice])
      assert_equal 0, ArtistClaim.count
      assert_nil Artist.find_by(name: "aichan_rival")
    end
  end
end
