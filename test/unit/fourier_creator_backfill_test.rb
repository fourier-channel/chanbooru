require "test_helper"

# The creator backfill for tunnel posts made before creators were recorded
# (operator ruling 2026-09-29), on fixtures covering every case the dry run
# must sort: exactly one poster tag, none, several, one that is not a tag the
# tunnel mints, one a later edit added, and posts that are not the tunnel's.
class FourierCreatorBackfillTest < ActiveSupport::TestCase
  context "FourierCreatorBackfill" do
    setup do
      # The tunnel's account as production names it, through the real list.
      @bot = create(:builder_user, name: "tunnel")
      @recorder = create(:admin_user)

      @one = create(:post, uploader: @bot, tag_string: "41chan_alice landscape")
      @none = create(:post, uploader: @bot, tag_string: "landscape")
      @two = create(:post, uploader: @bot, tag_string: "41chan_alice 41chan_bob")
      @odd = create(:post, uploader: @bot, tag_string: "41chan_a.b landscape")
      @later = create(:post, uploader: @bot, tag_string: "41chan_mallory landscape")
      @recorded = create(:post, uploader: @bot, tag_string: "41chan_carol")
      FourierPostCreator.create!(post: @recorded, mxid: "@dave:41chan.net", recorded_by: @recorder.id)
      @human = create(:post, tag_string: "41chan_erin")

      # First versions, as the archive keeps them: @later carried no poster
      # tag when it was created, so a later edit put it there. Whatever the
      # suite's mocked archive wrote for these posts is replaced, so the
      # fixture says exactly this and nothing else.
      PostVersion.where(post_id: [@one, @none, @two, @odd, @later, @recorded, @human].map(&:id)).delete_all
      as(@bot) do # belongs_to_updater takes the updater from CurrentUser
        create(:post_version, post: @one, version: 1, tags: @one.tag_string)
        create(:post_version, post: @later, version: 1, tags: "landscape")
      end
    end

    should "propose exactly-one poster tags and list every other post as unresolved" do
      plan = FourierCreatorBackfill.plan(uploader: @bot)

      assert_equal [[@one.id, "41chan_alice", "@alice:41chan.net", true]],
                   plan.proposals.map { [it.post_id, it.tag, it.mxid, it.at_creation] }
      unresolved = plan.unresolved.to_h { [it.post_id, it.reason] }
      assert_equal({ @none.id => "no 41chan_ tag", @two.id => "2 41chan_ tags", @odd.id => "not a poster tag", @later.id => "added after creation" }, unresolved)
      assert_equal 5, plan.scanned, "the recorded post and the person's post are not scanned"
    end

    should "print one tab-separated line per post and a summary, and write nothing" do
      lines = FourierCreatorBackfill.report_lines(FourierCreatorBackfill.plan(uploader: @bot))

      assert_includes lines, "PROPOSE\t#{@one.id}\t41chan_alice\t@alice:41chan.net\tyes"
      assert_includes lines, "UNRESOLVED\t#{@none.id}\tno 41chan_ tag\t"
      assert_includes lines, "UNRESOLVED\t#{@two.id}\t2 41chan_ tags\t41chan_alice,41chan_bob"
      assert_includes lines, "UNRESOLVED\t#{@later.id}\tadded after creation\t41chan_mallory"
      assert_match(/scanned 5 post\(s\) .*: 1 proposed \(0 with at_creation unknown\), 4 unresolved/, lines.last)
      assert lines.all?(&:ascii_only?)
      assert_equal 1, FourierPostCreator.count, "the dry run wrote a creator"
    end

    should "say when a proposal rests on the current tags alone" do
      PostVersion.where(post_id: @one.id).delete_all
      plan = FourierCreatorBackfill.plan(uploader: @bot)

      assert_nil plan.proposals.sole.at_creation
      assert_includes FourierCreatorBackfill.report_lines(plan), "PROPOSE\t#{@one.id}\t41chan_alice\t@alice:41chan.net\tunknown"
    end

    should "record the proposals, keep an existing creator, and be idempotent" do
      plan = FourierCreatorBackfill.plan(uploader: @bot)
      result = FourierCreatorBackfill.apply!(plan, recorded_by: @recorder)

      assert_equal({ recorded: 1, kept: 0, failed: [] }, result)
      row = FourierPostCreator.find_by!(post_id: @one.id)
      assert_equal "@alice:41chan.net", row.mxid
      assert_equal @recorder.id, row.recorded_by
      assert_equal "@dave:41chan.net", FourierPostCreator.find_by!(post_id: @recorded.id).mxid

      # A creator recorded between the plan and the apply stands.
      FourierPostCreator.where(post_id: @one.id).update_all(mxid: "@zed:41chan.net")
      assert_equal({ recorded: 0, kept: 1, failed: [] }, FourierCreatorBackfill.apply!(plan, recorded_by: @recorder))
      assert_equal "@zed:41chan.net", FourierPostCreator.find_by!(post_id: @one.id).mxid

      assert_empty FourierCreatorBackfill.plan(uploader: @bot).proposals
    end

    # A bot is known by name, so a renamed one silently becomes a person. The
    # script warns about every configured name with no account behind it.
    should "name each configured posting bot that matches no account" do
      assert_equal ["sample"], FourierCreatorBackfill.unmatched_bot_names

      create(:builder_user, name: "Sample")
      assert_empty FourierCreatorBackfill.unmatched_bot_names
    end

    should "report one failed post without stopping the rest" do
      plan = FourierCreatorBackfill.plan(uploader: @bot)
      plan.proposals.unshift(FourierCreatorBackfill::Proposal.new(post_id: 0, tag: "41chan_ghost", mxid: "@ghost:41chan.net", at_creation: nil))
      result = FourierCreatorBackfill.apply!(plan, recorded_by: @recorder)

      assert_equal 1, result[:recorded]
      assert_equal [0], result[:failed].map(&:first)
    end
  end
end
