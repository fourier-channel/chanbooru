# frozen_string_literal: true

require "test_helper"

# Tier 5, end to end: a creator whose claim on an artist tag has been approved
# may edit THAT artist and nothing else.
#
# The whole point of the tier is that it is not a general permission. A level
# alone confers nothing here; a level plus an approved claim confers control
# over exactly one artist's entry.
class ConfirmedCreatorTest < ActiveSupport::TestCase
  def tier5_user
    user = create(:user)
    # update_column on purpose: User validates level against User::Levels, and
    # 1-9 are not constants there yet -- the scale is still being designed and
    # editing an upstream model to make a test user is backwards.
    user.update_column(:level, 5) # rubocop:disable Rails/SkipsModelValidations
    user.reload
  end

  def claim_for(user, artist, mxid)
    gallery = CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
    ArtistClaim.create!(artist: artist, creator_gallery: gallery)
  end

  context "A confirmed creator" do
    setup do
      @artist = create(:artist)
      @other = create(:artist)
      @creator = tier5_user
      @claim = claim_for(@creator, @artist, "@maple:41chan.net")
    end

    should "not edit the artist while the claim is only pending" do
      assert_not(ArtistPolicy.new(@creator, @artist).update?)
    end

    context "with an approved claim" do
      setup { @claim.approve!(by: create(:moderator_user)) }

      should "edit the artist they claimed" do
        assert(ArtistPolicy.new(@creator, @artist).update?)
      end

      should "NOT edit any other artist" do
        assert_not(ArtistPolicy.new(@creator, @other).update?)
      end

      should "NOT delete the artist" do
        # The operator's line, and the reason this is not simply "treat them as
        # a member": control over one's own tag stops short of destroying it.
        assert_not(ArtistPolicy.new(@creator, @artist).destroy?)
      end

      should "NOT ban or unban" do
        assert_not(ArtistPolicy.new(@creator, @artist).ban?)
        assert_not(ArtistPolicy.new(@creator, @artist).unban?)
      end

      should "confer nothing on a banned account" do
        create(:ban, user: @creator)

        assert_not(ArtistPolicy.new(@creator.reload, @artist).update?)
      end

      should "confer nothing when the manifest denies the action at this level" do
        # The first thing the manifest actually decides. Moving artist.update up
        # to tier 7 must take it away from a tier 5 creator, claim or no claim.
        PermissionManifest.instance.stubs(:state).returns(:deny)

        assert_not(ArtistPolicy.new(@creator, @artist).update?)
      end
    end
  end

  context "An ordinary member" do
    should "keep editing artists without any claim at all" do
      # The grant must ADD a path, never replace the existing one.
      assert(ArtistPolicy.new(create(:user), create(:artist)).update?)
    end
  end
end
