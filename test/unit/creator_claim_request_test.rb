# frozen_string_literal: true

require "test_helper"

# The Claim Pool's one action (operator, 2026-11-05): a direct match of the
# page's Matrix name is the creator's at once; any other name goes to an
# admin in one request with the creator's note; the rest are refused, each
# saying why. A name hidden from the filer is filed whatever its state.
class CreatorClaimRequestTest < ActiveSupport::TestCase
  include TagQuarantineTestHelper

  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  def outcomes(results) = results.to_h { |result| [result.name, result.outcome] }

  context "Filing a claim request" do
    setup do
      @user = create(:user)
      @gallery = gallery_for(@user, "@maple:41chan.net")
      @admin = create(:admin_user)
      as(@admin) { create(:post, tag_string: "artist:4chan_maple artist:4chan_rival artist:aichan_maple") }
    end

    should "approve a direct match at once, by the system account, in the mod log, with no request" do
      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: ["4chan_maple"])

      assert_equal({ "4chan_maple" => :immediate }, outcomes(results))
      claim = ArtistClaim.find_by!(tag_name: "4chan_maple")
      assert(claim.approved?)
      assert_equal(User.system, claim.approver)
      assert_not(claim.by_review?)
      assert(ArtistClaim.owner?(@user, claim.artist))
      assert_match(/automatically: a direct match/, ModAction.last.description)
      assert_equal(0, CreatorClaimRequest.count, "a filing of direct matches alone leaves no ticket")
    end

    should "file any other name for an admin, under one request carrying the note" do
      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: ["4chan_rival"], note: "  I posted as rival on /b/  ")

      assert_equal({ "4chan_rival" => :requested }, outcomes(results))
      request = CreatorClaimRequest.sole
      assert_equal("I posted as rival on /b/", request.note)
      claim = request.artist_claims.sole
      assert(claim.pending?)
      assert(claim.by_review?)
      assert_not(ArtistClaim.owner?(@user, claim.artist), "a request confers nothing until an admin approves it")

      claim.approve!(by: @admin)
      assert(ArtistClaim.owner?(@user, claim.artist), "approved by review, the name is theirs as a direct match is")
      assert_includes(ArtistClaim.standing, ["4chan_rival", @gallery.id])
    end

    should "take every name on its own, saying what became of each" do
      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: ["4chan_maple", "4chan_rival", "4chan_nobody", "41chan_maple", "some_painter", "4chan_rival"])

      assert_equal({ "4chan_maple" => :immediate, "4chan_rival" => :requested, "4chan_nobody" => :refused, "41chan_maple" => :refused, "some_painter" => :refused },
                   outcomes(results))
      reasons = results.to_h { |result| [result.name, result.reason] }
      assert_match(/nothing is posted under 4chan_nobody yet/, reasons["4chan_nobody"])
      assert_match(/needs no claim/, reasons["41chan_maple"])
      assert_match(/not a locked creator tag/, reasons["some_painter"])
      assert_equal(["4chan_rival"], CreatorClaimRequest.sole.artist_claims.pluck(:tag_name))
      assert_not(Artist.exists?(name: "4chan_nobody"), "a refused name leaves no entry behind")
    end

    should "refuse a name another creator holds, when the filer can see it" do
      ArtistClaim.create!(artist: create(:artist, name: "4chan_rival"), creator_gallery: gallery_for(create(:user), "@rival:41chan.net")).approve!(by: @admin)

      result = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: ["4chan_rival"]).sole

      assert_equal(:refused, result.outcome)
      assert_match(/another creator's by an approved claim; if it is held wrongly, say so to an admin/, result.reason)
    end

    # aichan_ is visible to admins only (config/fourier/creator_prefixes.yml):
    # to this filer, a held name, an unposted name and a free one must read
    # alike, or the answer says which hidden names exist.
    should "file a name hidden from the filer whatever its state, and let approval refuse what it must" do
      held = ArtistClaim.create!(artist: create(:artist, name: "aichan_rival"), creator_gallery: gallery_for(create(:user), "@rival:41chan.net"))
      held.approve!(by: @admin)

      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: %w[aichan_rival aichan_ghost])

      assert_equal({ "aichan_rival" => :requested, "aichan_ghost" => :requested }, outcomes(results))
      claim = ArtistClaim.pending.find_by!(tag_name: "aichan_rival")
      error = assert_raises(ActiveRecord::RecordInvalid) { claim.approve!(by: @admin) }
      assert_includes(error.message, "already has an approved claim")
    end

    should "judge each name as filing it would" do
      %w[4chan_maple 4chan_rival 4chan_nobody 41chan_maple aichan_ghost].each do |name|
        _, judged, = CreatorClaimRequest.judge(@gallery, @user, name)
        filed = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: [name]).sole.outcome

        assert_equal(judged, filed, name)
      end
    end

    should "refuse a page not linked to the filer" do
      result = CreatorClaimRequest.file!(gallery: @gallery, user: create(:user), names: ["4chan_rival"]).sole

      assert_equal(:refused, result.outcome)
      assert_match(/Link this page/, result.reason)
    end

    should "refuse more than #{CreatorClaimRequest::MAX_NAMES} names at once" do
      names = (1..(CreatorClaimRequest::MAX_NAMES + 1)).map { |n| "4chan_name#{n}" }

      assert_raises(ArgumentError) { CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: names) }
    end

    # A tag withheld from the filer (here flagged, below admin) reads as one
    # nothing is posted under, word for word, or the answer says it exists.
    should "answer a tag the filer may not see as one nothing is posted under" do
      flag_tags!("4chan_rival")

      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: %w[4chan_rival 4chan_nobody])

      assert_equal({ "4chan_rival" => :refused, "4chan_nobody" => :refused }, outcomes(results))
      assert_equal(["nothing is posted under 4chan_rival yet", "nothing is posted under 4chan_nobody yet"], results.map { |result| result.reason[/\Anothing is posted under \S+ yet/] })
    end

    should "refuse a name for review once #{CreatorClaimRequest::MAX_WAITING} of the page's names wait, and still take a direct match" do
      waiting = (1..CreatorClaimRequest::MAX_WAITING).map { |n| "aichan_wait#{n}" }
      waiting.each_slice(CreatorClaimRequest::MAX_NAMES) { |names| CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: names) }

      results = CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: %w[4chan_rival 4chan_maple])

      assert_equal({ "4chan_rival" => :refused, "4chan_maple" => :immediate }, outcomes(results))
      assert_match(/#{CreatorClaimRequest::MAX_WAITING} names wait for an admin already/, results.first.reason)
    end
  end

  # The Identity dashboard's Claim Pool (operator, 2026-11-05): it starts with
  # the page's direct-name counterparts, grows by a creator search, and shows
  # every name it lists with what filing it would do.
  context "The Claim Pool" do
    setup do
      @user = create(:user)
      @gallery = gallery_for(@user, "@maple:41chan.net")
      @admin = create(:admin_user)
      as(@admin) do
        create(:post, tag_string: "artist:4chan_maple artist:4chan_maplewood artist:aichan_maplewood")
        create(:post, tag_string: "artist:4chan_maplewood maple_leaf")
      end
    end

    should "start with the page's counterparts under every prefix but the master one" do
      assert_equal(%w[4chan_maple aichan_maple], CreatorClaimRequest.counterparts(@gallery))
    end

    should "find the creator names the searcher may see, most used first, and never a hidden one" do
      assert_equal(%w[4chan_maplewood 4chan_maple], CreatorClaimRequest.search(@user, "maple"))
      assert_includes(CreatorClaimRequest.search(@admin, "maple"), "aichan_maplewood", "an admin sees aichan_")
      assert_equal([], CreatorClaimRequest.search(@user, "m"), "a one-letter search finds nothing")
    end

    should "list a whole name under a prefix first, so a hidden one can be asked for without saying it exists" do
      assert_equal(["aichan_maplewood"], CreatorClaimRequest.search(@user, "aichan_maplewood"))
      assert_equal(["aichan_nobody"], CreatorClaimRequest.search(@user, "aichan_nobody"))
      assert_equal(%w[4chan_maplew 4chan_maplewood], CreatorClaimRequest.search(@user, "4chan_maplew"))
    end

    should "judge every row as filing would, leaving out a name the page already holds or awaits" do
      rows = CreatorClaimRequest.pool(@gallery, @user, %w[4chan_maple aichan_maple 4chan_maplewood aichan_maplewood 4chan_maple])

      assert_equal({ "4chan_maple" => :immediate, "aichan_maple" => :refused, "4chan_maplewood" => :requested, "aichan_maplewood" => :requested },
                   outcomes(rows))
      assert_match(/nothing is posted under aichan_maple yet/, rows.find { |row| row.name == "aichan_maple" }.reason)

      CreatorClaimRequest.file!(gallery: @gallery, user: @user, names: %w[4chan_maple 4chan_maplewood])
      assert_equal(["aichan_maplewood"], CreatorClaimRequest.pool(@gallery, @user, %w[4chan_maple 4chan_maplewood aichan_maplewood]).map(&:name))
    end
  end
end
