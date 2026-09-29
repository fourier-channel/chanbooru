require "test_helper"

# Private creator tags that still sit in a post's PUBLIC tag_string (round-two
# finding 15), taken out through the ordinary post edit. The fixtures are the
# two shapes production holds: the tunnel's since 37270f5, where a private tag
# is only its sidecar row, and the two days before it, where the tunnel put
# the private tag in tag_string as well.
class FourierPrivateTagCleanupTest < ActiveSupport::TestCase
  SECRET = "secret_prompt_tag"

  context "FourierPrivateTagCleanup" do
    setup do
      @bot = create(:builder_user)
      @admin = create(:admin_user)
      as(@bot) do
        # 2026-08-04..06: the private tag is ALSO in tag_string.
        @legacy = create(:post, uploader: @bot, tag_string: "41chan_alice landscape #{SECRET}")
        # Since 37270f5: the private tag is its row and nothing else.
        @current = create(:post, uploader: @bot, tag_string: "41chan_bob landscape")
        # The same name, public here: another post's private row is not this
        # post's, so this one is never listed.
        @plain = create(:post, uploader: @bot, tag_string: "landscape #{SECRET}")
      end
      FourierTagSource.record_partition!(@legacy, { creator: [SECRET], auto: %w[landscape] }, @bot)
      FourierTagSource.record_partition!(@current, { creator: [SECRET], auto: %w[landscape] }, @bot)
      FourierPostCreator.create!(post: @legacy, mxid: "@alice:41chan.net", recorded_by: @bot.id)
    end

    should "list only the posts whose tag_string carries one of their own private tags" do
      plan = FourierPrivateTagCleanup.plan

      assert_equal({ @legacy.id => [SECRET] }, plan.posts)
      assert plan.versions_kept
    end

    should "print post ids and counts, and never a tag" do
      lines = FourierPrivateTagCleanup.report_lines(FourierPrivateTagCleanup.plan)

      assert_includes lines, "POST\t#{@legacy.id}\t1"
      assert_match(/1 post\(s\) carry 1 private creator tag\(s\)/, lines.last)
      assert lines.none? { |line| line.include?(SECRET) }, lines.join("\n")
      assert lines.all?(&:ascii_only?)
    end

    should "remove the tag through an ordinary, versioned, revertible edit and leave the row private" do
      result = FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)

      assert_equal({ removed: [[@legacy.id, 1]], kept: [], unchanged: [], failed: [] }, result)
      assert_equal %w[41chan_alice landscape], @legacy.reload.tag_array
      row = FourierTagSource.find_by!(post_id: @legacy.id, tag: SECRET)
      assert_equal false, row.public, "the row is the creator's and stays private"

      version = @legacy.versions.order(:version).last
      assert_equal [SECRET], version.removed_tags
      assert_equal @admin.id, version.updater_id

      # The creator still sees it: a private row is drawn for the creator
      # whether or not its tag is in tag_string.
      creator = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => "@alice:41chan.net")
      assert_includes FourierTagSource.for_viewer(@legacy, nil, request: creator)[:creator], SECRET
      assert_empty FourierTagSource.for_viewer(@legacy, nil)[:creator]

      # Revertible like any edit: the version before it still has the tag.
      before = @legacy.versions.order(:version).find { |v| v.tag_array.include?(SECRET) }
      as(@admin) do
        @legacy.revert_to(before)
        @legacy.save!
      end
      assert_includes @legacy.reload.tag_array, SECRET
    end

    should "re-read each post, and leave one whose tag is already gone alone" do
      plan = FourierPrivateTagCleanup.plan
      @legacy.update_columns(tag_string: "41chan_alice landscape")

      result = FourierPrivateTagCleanup.apply!(plan, user: @admin)
      assert_equal [@legacy.id], result[:unchanged]
      assert_empty result[:removed]
    end

    should "report a tag the ordinary edit puts back as kept, not removed" do
      create(:tag_implication, antecedent_name: "landscape", consequent_name: SECRET)

      result = FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)
      assert_equal [[@legacy.id, 1]], result[:kept]
      assert_empty result[:removed]
      assert_includes @legacy.reload.tag_array, SECRET
    end

    should "report one failed post without stopping the rest" do
      plan = FourierPrivateTagCleanup.plan
      plan.posts = { 0 => [SECRET] }.merge(plan.posts)

      result = FourierPrivateTagCleanup.apply!(plan, user: @admin)
      assert_equal [0], result[:failed].map(&:first)
      assert_equal [[@legacy.id, 1]], result[:removed]
    end

    should "never name a private tag in a failure line" do
      Post.any_instance.stubs(:update!).raises(StandardError, "tag #{SECRET} could not be saved")

      result = FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)
      assert_equal [[@legacy.id, "StandardError: tag [private tag] could not be saved"]], result[:failed]
      lines = FourierPrivateTagCleanup.result_lines(result, user: @admin)
      assert lines.none? { |line| line.include?(SECRET) }, lines.join("\n")
      assert_includes @legacy.reload.tag_array, SECRET
    end
  end
end
