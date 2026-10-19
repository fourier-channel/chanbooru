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
      # "tunnel": creator tags are locked to the posting accounts (CreatorPrefixes).
      @bot = create(:builder_user, name: "tunnel")
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

      # Revertible by the post's creator alone: the version before it still
      # has the tag, and putting it back publishes the creator's prompt
      # again, so an admin's revert is refused (FourierPrivateTagLineage,
      # BUR review 2026-10-19: no admin bypass).
      before = @legacy.versions.order(:version).find { |v| v.tag_array.include?(SECRET) }
      assert_raises(FourierPrivateTagLineage::RestoreRefused) { as(@admin) { @legacy.revert_to(before) } }
      assert_equal %w[41chan_alice landscape], @legacy.tag_array, "a refused revert assigns nothing"
      CurrentUser.set(user: create(:user), request: creator) do
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

    should "report a tag the ordinary edit puts back as kept, not removed, and name every cause" do
      create(:tag_implication, antecedent_name: "landscape", consequent_name: SECRET)

      result = FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)
      assert_equal [[@legacy.id, 1]], result[:kept]
      assert_empty result[:removed]
      assert_includes @legacy.reload.tag_array, SECRET

      # The ordinary edit re-adds an implied tag AND what the booru derives
      # itself (Post#add_automatic_tags from the file, Tag.automatic_tags_for
      # from another tag's name); the remedy must not name implications alone.
      kept = FourierPrivateTagCleanup.result_lines(result, user: @admin).find { |line| line.start_with?("KEPT") }
      assert_match(/implies/, kept)
      assert_match(/derives from the file or from another tag's name/, kept)
    end

    # The plan lists a tag only where the POSTING BOT put that occurrence on
    # the public list (FourierPrivateTagLineage). Anyone else's add is that
    # person's own choice, public to everyone (operator, 2026-10-19).
    should "not plan a tag a person, a bulk update or an implication put on the public list" do
      member = create(:user)
      as(@bot) do
        @typed = create(:post, uploader: @bot, tag_string: "landscape")
        @bulk = create(:post, uploader: @bot, tag_string: "bulk_source")
        @implied = create(:post, uploader: @bot, tag_string: "implying_source")
      end
      { @typed => "typed_secret", @bulk => "bulk_secret", @implied => "implied_secret" }.each do |post, name|
        FourierTagSource.record_partition!(post, { creator: [name] }, @bot)
      end
      as(member) { @typed.update!(tag_string: "landscape typed_secret") }
      create_bur!("mass update bulk_source -> bulk_secret", @admin)
      TagImplication.approve!(antecedent_name: "implying_source", consequent_name: "implied_secret", approver: @admin)
      assert_includes @typed.reload.tag_array, "typed_secret", "fixture"
      assert_includes @bulk.reload.tag_array, "bulk_secret", "fixture"
      assert_includes @implied.reload.tag_array, "implied_secret", "fixture"

      plan = FourierPrivateTagCleanup.plan
      assert_equal({ @legacy.id => [SECRET] }, plan.posts, "the bot's legacy add stays planned; the three public adds do not")
      assert_equal 3, plan.skipped[:public]
      lines = FourierPrivateTagCleanup.report_lines(plan)
      assert_includes lines, "# 3 pair(s) skipped: put on the public list by a person, a bulk update or an implication -- that edit's own choice, not a leak"
      assert lines.none? { |line| line.match?(/typed_secret|bulk_secret|implied_secret/) }, lines.join("\n")
    end

    should "not plan a label the posting bot publishes on purpose, though the prompt names it too" do
      as(@bot) do
        @ai = create(:post, uploader: @bot, tag_string: "landscape ai-generated")
        @discord = create(:post, uploader: @bot, tag_string: "landscape no_train")
      end
      FourierTagSource.record_partition!(@ai, { creator: ["ai-generated"], auto: %w[landscape] }, @bot)
      FourierTagSource.record_partition!(@discord, { creator: ["no_train"], auto: %w[landscape] }, @bot)

      plan = FourierPrivateTagCleanup.plan
      assert_equal({ @legacy.id => [SECRET] }, plan.posts)
      assert_equal 2, plan.skipped[:label]
      assert_includes FourierPrivateTagCleanup.report_lines(plan), "# 2 pair(s) skipped: a label the posting bot publishes on purpose, not a leak"
    end

    should "plan a bot leak an alias or a rename moved, under the name it now has" do
      as(@bot) { @renamed = create(:post, uploader: @bot, tag_string: "landscape rename_leak") }
      FourierTagSource.record_partition!(@renamed, { creator: ["rename_leak"], auto: %w[landscape] }, @bot)
      TagAlias.approve!(antecedent_name: SECRET, consequent_name: "aliased_secret", approver: @admin)
      create_bur!("rename rename_leak -> renamed_leak", @admin)
      assert_includes @legacy.reload.tag_array, "aliased_secret", "fixture"
      assert_includes @renamed.reload.tag_array, "renamed_leak", "fixture"

      plan = FourierPrivateTagCleanup.plan
      assert_equal({ @legacy.id => ["aliased_secret"], @renamed.id => ["renamed_leak"] }, plan.posts)
    end

    should "not plan a tag whose add its history cannot show, and count it apart" do
      @legacy.versions.order(:version).first.update_columns(version: 2) # rubocop:disable Rails/SkipsModelValidations

      plan = FourierPrivateTagCleanup.plan
      assert_empty plan.posts
      assert_equal 1, plan.skipped[:unknown]
      assert_includes FourierPrivateTagCleanup.report_lines(plan), "# 1 pair(s) skipped: who added them cannot be read from the post's versions; nothing is removed blind"
    end

    should "plan nothing where post versions are not kept, and say why" do
      PostVersion.stubs(:enabled?).returns(false)

      plan = FourierPrivateTagCleanup.plan
      assert_empty plan.posts
      assert_not plan.versions_kept
      assert_equal 1, plan.skipped[:unknown]
      assert_match(/who added each tag cannot be read, so nothing is planned/, FourierPrivateTagCleanup.report_lines(plan).first)
    end

    should "remove only the bot's occurrences from a post that also carries a tag a person typed" do
      FourierTagSource.record_partition!(@legacy, { creator: [SECRET, "typed_secret"], auto: %w[landscape] }, @bot)
      as(create(:user)) { @legacy.update!(tag_string: "41chan_alice landscape #{SECRET} typed_secret") }

      plan = FourierPrivateTagCleanup.plan
      assert_equal({ @legacy.id => [SECRET] }, plan.posts)
      result = FourierPrivateTagCleanup.apply!(plan, user: @admin)
      assert_equal [[@legacy.id, 1]], result[:removed]
      assert_equal %w[41chan_alice landscape typed_secret], @legacy.reload.tag_array
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
