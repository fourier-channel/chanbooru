# frozen_string_literal: true

require "test_helper"

class ArtistClaimTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  context "An artist claim" do
    setup do
      @artist = create(:artist)
      @user = create(:user)
      @gallery = gallery_for(@user, "@maple:41chan.net")
    end

    should "not make anyone an owner while it is pending" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)

      assert_not(ArtistClaim.owner?(@user, @artist), "a pending claim must confer nothing")
    end

    should "make the claimant an owner once approved" do
      claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
      claim.approve!(by: create(:moderator_user))

      assert(ArtistClaim.owner?(@user, @artist))
    end

    should "confer nothing on anyone else" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: create(:moderator_user))

      assert_not(ArtistClaim.owner?(create(:user), @artist))
      assert_not(ArtistClaim.owner?(User.anonymous, @artist))
      assert_not(ArtistClaim.owner?(nil, @artist))
    end

    should "confer nothing on a different artist" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: create(:moderator_user))

      assert_not(ArtistClaim.owner?(@user, create(:artist)))
    end

    should "refuse a second approved claim on one artist" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: create(:moderator_user))

      rival = ArtistClaim.new(artist: @artist, creator_gallery: gallery_for(create(:user), "@rival:41chan.net"),
                              status: ArtistClaim::APPROVED)

      assert_not(rival.valid?)
      assert_includes(rival.errors.full_messages.join, "already has an approved claim")
    end

    should "still allow a rejected claimant to ask again" do
      # A rejection that permanently barred someone from re-applying would make
      # a moderator's "not yet" indistinguishable from "never", which is not a
      # decision anyone intended to be making.
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).reject!(by: create(:moderator_user))

      assert_nothing_raised { ArtistClaim.create!(artist: @artist, creator_gallery: @gallery) }
    end
  end
end
