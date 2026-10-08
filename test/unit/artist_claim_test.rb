# frozen_string_literal: true

require "test_helper"

# A claim on a creator tag (design CREATOR_VISIBILITY section 9, ruled
# 2026-10-07): keyed on the TAG NAME, valid only for a tag the live prefix list
# locks and only for the gallery whose verified Matrix localpart it strips to
# (operator ruling 2026-10-04), approved or rejected by an admin alone (Q6),
# every decision written to the mod log.
class ArtistClaimTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  context "An artist claim" do
    setup do
      @artist = create(:artist, name: "4chan_maple")
      @user = create(:user)
      @gallery = gallery_for(@user, "@maple:41chan.net")
      @admin = create(:admin_user)
    end

    should "not make anyone an owner while it is pending" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)

      assert_not(ArtistClaim.owner?(@user, @artist), "a pending claim must confer nothing")
    end

    should "make the claimant an owner once approved" do
      claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
      claim.approve!(by: @admin)

      assert(ArtistClaim.owner?(@user, @artist))
    end

    should "confer nothing on anyone else" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: @admin)

      assert_not(ArtistClaim.owner?(create(:user), @artist))
      assert_not(ArtistClaim.owner?(User.anonymous, @artist))
      assert_not(ArtistClaim.owner?(nil, @artist))
    end

    should "confer nothing on a different artist" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: @admin)

      assert_not(ArtistClaim.owner?(@user, create(:artist, name: "aichan_maple")))
    end

    should "refuse a second approved claim on one tag" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: @admin)

      rival = ArtistClaim.new(artist: @artist, creator_gallery: gallery_for(create(:user), "@maple:other.example"),
                              status: ArtistClaim::APPROVED)

      assert_not(rival.valid?)
      assert_includes(rival.errors.full_messages.join, "already has an approved claim")
    end

    should "refuse a second pending claim on one tag from the same gallery" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)

      again = ArtistClaim.new(artist: @artist, creator_gallery: @gallery)

      assert_not(again.valid?)
      assert_includes(again.errors.full_messages.join, "already waiting")
    end

    context "its tag name" do
      should "be the artist's name when the claim is filed" do
        assert_equal("4chan_maple", ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).tag_name)
      end

      # Any unbanned member can rename an Artist. Keyed on artist_id, an
      # approved claim followed the rename onto whatever tag the artist was
      # renamed to; keyed on the tag, renaming moves nothing.
      should "not follow a rename of the artist" do
        claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
        claim.approve!(by: @admin)
        @artist.update!(name: "4chan_victim")

        assert_equal("4chan_maple", claim.reload.tag_name)
        assert_equal("4chan_maple", ArtistClaim.approved.sole.tag_name)
      end

      should "never change once filed" do
        claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
        claim.tag_name = "4chan_victim"

        assert_not(claim.valid?)
        assert_includes(claim.errors.full_messages.join, "cannot change")
        assert_raises(ActiveRecord::RecordInvalid) { claim.save! }
        assert_equal("4chan_maple", claim.reload.tag_name)
      end
    end

    # Operator ruling 2026-10-04: a claim on <prefix>_X is valid only for the
    # gallery whose verified localpart is X.
    context "the stripped-name rule" do
      should "let a Matrix account claim the creator tags that strip to its own name" do
        %w[4chan_maple aichan_maple].each do |name|
          artist = Artist.find_by(name: name) || create(:artist, name: name)
          assert(ArtistClaim.new(artist: artist, creator_gallery: @gallery).valid?, name)
        end
      end

      should "refuse a creator tag that strips to someone else's name" do
        %w[4chan_maplex aichan_rival].each do |name|
          claim = ArtistClaim.new(artist: create(:artist, name: name), creator_gallery: @gallery)
          assert_not(claim.valid?, name)
          assert_includes(claim.errors.full_messages.join, "identical to the claimant's Matrix name", name)
        end
      end

      # Q6: "41chan_<self> needs no claim". The master tag is the Matrix
      # account's already (CreatorControl); a claim on it would only put a
      # no-op in the admin queue.
      should "refuse the master prefix, which needs no claim" do
        claim = ArtistClaim.new(artist: create(:artist, name: "41chan_maple"), creator_gallery: @gallery)

        assert_not(claim.valid?)
        assert_includes(claim.errors.full_messages.join, "needs no claim")
      end
    end

    context "the live prefix list" do
      setup do
        @dir = Dir.mktmpdir("artist-claim-prefixes")
        @path = File.join(@dir, "creator_prefixes.yml")
        @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
        ENV["FOURIER_CREATOR_PREFIXES"] = @path
        CreatorPrefixes.reset!
        File.write(@path, <<~YAML)
          editors: [tunnel]
          prefixes:
            - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
            - {prefix: newsite_, provenance: Web, target_kind: site, target: example.org, scope: x}
        YAML
      end

      teardown do
        ENV["FOURIER_CREATOR_PREFIXES"] = @was
        CreatorPrefixes.reset!
        FileUtils.rm_rf(@dir)
      end

      # The old rule was a hardcoded (4chan|41chan|aichan) regex: a prefix
      # added to the live list was outside it, so its tags skipped the
      # stripped-name check entirely.
      should "apply the stripped-name rule to a prefix the code has never heard of" do
        assert(ArtistClaim.new(artist: create(:artist, name: "newsite_maple"), creator_gallery: @gallery).valid?)

        rival = ArtistClaim.new(artist: create(:artist, name: "newsite_rival"), creator_gallery: @gallery)
        assert_not(rival.valid?)
        assert_includes(rival.errors.full_messages.join, "identical to the claimant's Matrix name")
      end

      should "refuse a tag whose prefix has left the list" do
        claim = ArtistClaim.new(artist: @artist, creator_gallery: @gallery)

        assert_not(claim.valid?, "4chan_ is not in this list")
        assert_includes(claim.errors.full_messages.join, "not a locked creator tag")
      end

      should "re-check the rule at approval, against the list as it is then" do
        claim = ArtistClaim.create!(artist: create(:artist, name: "newsite_maple"), creator_gallery: @gallery)
        File.write("#{@path}.tmp", File.read(@path).sub(/^.*newsite_.*\n/, ""))
        File.rename("#{@path}.tmp", @path)

        assert_raises(ActiveRecord::RecordInvalid) { claim.approve!(by: @admin) }
        assert(claim.reload.pending?)
      end
    end

    # A tag outside the lock is one any member can add to any post, so a claim
    # on it would hand its holder whatever posts someone chose to tag.
    should "refuse a tag that no listed prefix locks" do
      claim = ArtistClaim.new(artist: create(:artist, name: "some_painter"), creator_gallery: @gallery)

      assert_not(claim.valid?)
      assert_includes(claim.errors.full_messages.join, "not a locked creator tag")
    end

    context "deciding" do
      setup { @claim = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery) }

      # Q6: admins approve. A moderator issues TagGrants, and the creator
      # control this claim keys must not be a moderator's to hand out.
      should "refuse an approval or rejection by anyone but an admin" do
        [create(:moderator_user), create(:user), User.anonymous, nil].each do |user|
          assert_raises(User::PrivilegeError, user&.name.inspect) { @claim.approve!(by: user) }
          assert_raises(User::PrivilegeError, user&.name.inspect) { @claim.reject!(by: user, note: "no") }
        end

        assert(@claim.reload.pending?)
        assert_equal(0, ModAction.where(category: %w[artist_claim_approve artist_claim_reject]).count)
      end

      should "log an approval to the mod log, for admins only" do
        @claim.approve!(by: @admin)

        action = ModAction.last
        assert_equal(["artist_claim_approve", @admin, @artist], [action.category, action.creator, action.subject])
        assert_includes(action.description, "4chan_maple")
        assert_includes(action.description, "@maple:41chan.net")
        assert_includes(ModAction.visible(@admin), action)
        assert_not_includes(ModAction.visible(create(:moderator_user)), action)
        assert_not_includes(ModAction.visible(User.anonymous), action)
        assert(ModActionPolicy.new(@admin, action).show?)
        assert_not(ModActionPolicy.new(create(:moderator_user), action).show?)
      end

      should "log a rejection with its note" do
        @claim.reject!(by: @admin, note: "not you")

        action = ModAction.last
        assert_equal(["artist_claim_reject", @admin], [action.category, action.creator])
        assert_includes(action.description, "not you")
        assert_equal("not you", @claim.reload.note)
      end

      should "still allow a rejected claimant to ask again" do
        # A rejection that permanently barred someone from re-applying would
        # make an admin's "not yet" indistinguishable from "never", which is not
        # a decision anyone intended to be making.
        @claim.reject!(by: @admin)

        assert_nothing_raised { ArtistClaim.create!(artist: @artist, creator_gallery: @gallery) }
      end

      should "approve only a pending claim" do
        @claim.reject!(by: @admin)

        assert_raises(ActiveRecord::RecordInvalid) { @claim.approve!(by: @admin) }
        assert(@claim.reload.rejected?)
      end

      # An approval made in error has to be undoable by the same people who
      # made it, through the same logged verb.
      should "let an admin withdraw an approval by rejecting it" do
        @claim.approve!(by: @admin)
        @claim.reject!(by: @admin, note: "withdrawn")

        assert(@claim.reload.rejected?)
        assert_equal(%w[artist_claim_approve artist_claim_reject], ModAction.order(:id).pluck(:category))
      end
    end

    # A tag one gallery holds by approval cannot be won by filing: the second
    # claim could never be approved while the first stands, so it is refused
    # at filing with the way out (an admin withdraws the first).
    should "refuse to file a claim on a tag another gallery already holds" do
      ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: @admin)
      rival = ArtistClaim.new(artist: @artist, creator_gallery: gallery_for(create(:user), "@maple:other.example"))

      assert_not(rival.valid?)
      assert_includes(rival.errors.full_messages.join, "already has an approved claim")
    end

    # Any unbanned member can rename an Artist. The claim stays on its tag, but
    # the renamed ROW still carries its approval, and the per-artist index
    # (kept, additive migration) allows one approved claim per row: a claim
    # filed against that row under its new name could never be approved. It
    # is refused with the reason instead of a database error at approval.
    context "on an artist entry renamed under an approved claim" do
      setup do
        ArtistClaim.create!(artist: @artist, creator_gallery: @gallery).approve!(by: @admin)
        @artist.update!(name: "4chan_victim")
        @victim_gallery = gallery_for(create(:user), "@victim:41chan.net")
      end

      should "move editing rights with the name, not the row" do
        assert_not(ArtistClaim.owner?(@user, @artist), "the entry now named 4chan_victim is not maple's to edit")
        assert(ArtistClaim.owner?(@user, create(:artist, name: "4chan_maple")), "the entry named 4chan_maple is")
      end

      should "refuse a claim filed against the renamed entry, naming the rename" do
        claim = ArtistClaim.new(artist: @artist, creator_gallery: @victim_gallery)

        assert_not(claim.valid?)
        assert_includes(claim.errors.full_messages.join, "approved claim on 4chan_maple")
      end
    end

    should "refuse at approval, readably, a claim whose entry has since been approved under another tag" do
      maple = ArtistClaim.create!(artist: @artist, creator_gallery: @gallery)
      @artist.update!(name: "4chan_victim")
      victim = ArtistClaim.create!(artist: @artist, creator_gallery: gallery_for(create(:user), "@victim:41chan.net"))
      maple.approve!(by: @admin)

      error = assert_raises(ActiveRecord::RecordInvalid) { victim.approve!(by: @admin) }
      assert_includes(error.message, "approved claim on 4chan_maple")
      assert(victim.reload.pending?)
    end

    # The one check behind every "Claim" button and the filing itself, so an
    # offer never leads to a refusal.
    context "the filing check" do
      should "take a claim the linked, unbanned account may file" do
        claim, refusal = ArtistClaim.prepare(@gallery, @user, "4chan_maple")

        assert_nil(refusal)
        assert_equal([@artist, "4chan_maple"], [claim.artist, claim.tag_name])
      end

      should "refuse a banned account, and any account the gallery is not linked to" do
        banned = create(:banned_user)
        gallery = gallery_for(banned, "@maplebanned:41chan.net")

        assert_match(/banned/, ArtistClaim.prepare(gallery, banned, "4chan_maplebanned").second)
        assert_match(/Link this page/, ArtistClaim.prepare(@gallery, create(:user), "4chan_maple").second)
        assert_match(/Link this page/, ArtistClaim.prepare(@gallery, User.anonymous, "4chan_maple").second)
      end

      should "refuse a tag no Artist entry could be made for" do
        as(@admin) { create(:post, tag_string: "aichan_maple") }

        assert_match(/general tag/, ArtistClaim.prepare(@gallery, @user, "aichan_maple").second)
      end

      should "refuse what the claim rule refuses, in its words" do
        assert_match(/identical to the claimant's Matrix name/, ArtistClaim.prepare(@gallery, @user, "4chan_rival").second)
      end
    end
  end
end
