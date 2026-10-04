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

    # Operator ruling 2026-10-04: 41chan_ is the master; 4chan_ and aichan_ are
    # claimable by it only when identical once the prefix is stripped.
    should "let a Matrix account claim the 4chan_ and aichan_ tags that strip to its own name" do
      %w[4chan_maple aichan_maple 41chan_maple].each do |name|
        artist = create(:artist, name: name)
        assert(ArtistClaim.new(artist: artist, creator_gallery: @gallery).valid?, name)
      end
    end

    should "refuse a prefixed creator tag that strips to someone else's name" do
      %w[4chan_maplex aichan_rival 41chan_rival].each do |name|
        claim = ArtistClaim.new(artist: create(:artist, name: name), creator_gallery: @gallery)
        assert_not(claim.valid?, name)
        assert_includes(claim.errors.full_messages.join, "identical to the claimant's 41chan_ name", name)
      end
    end

    should "leave a tag without a creator prefix to the existing claim flow" do
      assert(ArtistClaim.new(artist: create(:artist, name: "some_painter"), creator_gallery: @gallery).valid?)
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
