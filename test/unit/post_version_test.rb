require "test_helper"

class PostVersionTest < ActiveSupport::TestCase
  # Fork: @post's versions as they are shown to `user`, with no Matrix identity.
  def history(user)
    PostVersion.where(post_id: @post.id).order(:version, :id).redacting_private_tags_for(user, nil).to_a
  end

  # Fork: the ids of @post's versions a history search finds for `user`.
  def found(user, **search)
    PostVersion.search(search, user).where(post_id: @post.id).map(&:id).sort
  end

  context "A post" do
    setup do
      travel_to(1.month.ago) do
        @user = create(:user)
      end
      CurrentUser.user = @user
    end

    teardown do
      CurrentUser.user = nil
    end

    context "that has multiple versions: " do
      setup do
        PostVersion.sqs_service.stubs(:merge?).returns(false)
        @post = create(:post, tag_string: "1")
        @post.update(tag_string: "1 2")
        @post.update(tag_string: "2 3")
      end

      context "a version record" do
        setup do
          @version = PostVersion.last
        end

        should "know its previous version" do
          assert_not_nil(@version.previous)
          assert_equal("1 2", @version.previous.tags)
        end
      end
    end

    context "that has been created" do
      setup do
        @parent = create(:post)
        @post = create(:post, tag_string: "aaa bbb ccc", rating: "e", parent: @parent, source: "http://xyz.com")
      end

      should "also create a version" do
        assert_equal(1, @post.versions.size)
        @version = @post.versions.last
        assert_equal("aaa bbb ccc", @version.tags)
        assert_equal(@post.rating, @version.rating)
        assert_equal(@post.parent_id, @version.parent_id)
        assert_equal(@post.source, @version.source)
      end
    end

    context "that should be merged" do
      setup do
        @parent = create(:post)
        @post = create(:post, tag_string: "aaa bbb ccc", rating: "q", source: "http://xyz.com")
      end

      should "delete the previous version" do
        assert_equal(1, @post.versions.count)
        @post.update(tag_string: "bbb ccc xxx", source: "")
        @post.reload
        assert_equal(1, @post.versions.count)
      end
    end

    context "that is tagged with a pool:<name> metatag" do
      setup do
        @pool = create(:pool)
        @post = create(:post, tag_string: "tagme pool:#{@pool.id}")
      end

      should "create a version" do
        assert_equal("tagme", @post.tag_string)
        assert_equal([@pool.id], @post.pools.pluck(:id))

        assert_equal(1, @post.versions.size)
        assert_equal("tagme", @post.versions.last.tags)
      end
    end

    context "that has been updated" do
      setup do
        PostVersion.sqs_service.stubs(:merge?).returns(false)
        @post = create(:post, created_at: 1.minute.ago, tag_string: "aaa bbb ccc", rating: "q", source: "http://xyz.com")
        @post.update(tag_string: "bbb ccc xxx", source: "")
      end

      should "also create a version" do
        assert_equal(2, @post.versions.size)
        @version = @post.versions.last
        assert_equal("bbb ccc xxx", @version.tags)
        assert_equal("q", @version.rating)
        assert_equal("", @version.source)
        assert_nil(@version.parent_id)
      end

      should "not create a version if updating the post fails" do
        @post.stubs(:update_tag_category_counts).raises(NotImplementedError)

        assert_equal(2, @post.versions.size)
        assert_raise(NotImplementedError) { @post.update(rating: "s") }
        assert_equal(2, @post.versions.size)
      end

      should "should create a version if the rating changes" do
        assert_difference("@post.versions.size", 1) do
          @post.update(rating: "s")
          assert_equal("s", @post.versions.max_by(&:id).rating)
        end
      end

      should "should create a version if the source changes" do
        assert_difference("@post.versions.size", 1) do
          @post.update(source: "blah")
          assert_equal("blah", @post.versions.max_by(&:id).source)
        end
      end

      should "should create a version if the parent changes" do
        assert_difference("@post.versions.size", 1) do
          @parent = create(:post)
          @post.update(parent_id: @parent.id)
          assert_equal(@parent.id, @post.versions.max_by(&:id).parent_id)
        end
      end

      should "should create a version if the tags change" do
        assert_difference("@post.versions.size", 1) do
          @post.update(tag_string: "blah")
          assert_equal("blah", @post.versions.max_by(&:id).tags)
        end
      end
    end

    context "#undo" do
      setup do
        PostVersion.sqs_service.stubs(:merge?).returns(false)
        @post = create(:post, tag_string: "1")
        @post.update(tag_string: "1 2")
        @post.update(tag_string: "2 3")
      end

      should "undo the changes" do
        @post.versions[1].undo!
        assert_equal("3", @post.reload.tag_string)
      end
    end
  end

  # Fork: history withholds a creator's private tag only where that
  # occurrence is the posting bot's leak (or nobody's on record), judged by
  # its lineage (FourierPrivateTagLineage), and only once the post no longer
  # carries it. A person's own add of a tag the prompt also holds is that
  # person's public choice (operator ruling 2026-10-19), and history shows it
  # like any other edit; so does any tag the post still carries, which every
  # other page shows too.
  context "A post whose creator's private row names a tag" do
    setup do
      PostVersion.sqs_service.stubs(:merge?).returns(false)
      @tunnel = create(:builder_user, name: "tunnel")
      @member = create(:user)
      @admin = create(:admin_user)
      @viewer = create(:user)
    end

    should "show a member's own add of a tag that a creator's private row also names" do
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape") }
      FourierTagSource.record_partition!(@post, { creator: ["prompt_term"], auto: ["landscape"] }, @tunnel)
      as(@member) { @post.update!(tag_string: "landscape prompt_term") }

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        added = history(user).last
        assert_equal(%w[landscape prompt_term], added.tag_array, label)
        assert_equal(["prompt_term"], added.added_tags, label)
        assert_equal([added.id], found(user, changed_tags: "prompt_term"), label)
        assert_equal([added.id], found(user, tag_matches: "prompt_t*"), label)
      end
    end

    # A leak the post still carries is on its public list, which every other
    # page shows (operator ruling 2026-10-19); withholding it here alone told
    # a stranger it was a prompt term. Once it is taken off, the whole run is
    # withheld: the add, the alias's move (the system account's edit carrying
    # the bot's leak), and the removal.
    should "show a bot-leaked private tag while the post carries it, and withhold its whole run once it is taken off" do
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape leaked_term") }
      FourierTagSource.record_partition!(@post, { creator: ["leaked_term"], auto: ["landscape"] }, @tunnel)
      TagAlias.approve!(antecedent_name: "leaked_term", consequent_name: "moved_term", approver: @admin)
      assert_equal(%w[landscape moved_term], @post.reload.tag_array, "fixture: the alias moved the post")
      assert(FourierTagSource.exists?(post_id: @post.id, tag: "moved_term", public: false), "fixture: and the private row")
      assert_equal(User.system, @post.versions.order(:version).last.updater, "fixture: the move is the system account's")

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        leaked, moved = history(user)
        assert_equal(%w[landscape leaked_term], leaked.tag_array, label)
        assert_equal(["moved_term"], moved.added_tags, label)
        assert_equal(["leaked_term"], moved.removed_tags, label)
        assert_equal([leaked.id, moved.id].sort, found(user, changed_tags: "leaked_term"), label)
      end

      as(User.system) { @post.update!(tag_string: "landscape") }
      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        leaked, moved, cleaned = history(user)
        assert_equal(["landscape"], leaked.tag_array, label)
        assert_equal(["landscape"], moved.tag_array, label)
        assert_equal([[], []], [moved.added_tags, moved.removed_tags], label)
        assert_equal([], cleaned.removed_tags, label)
        assert_equal([], found(user, changed_tags: "moved_term"), label)
        assert_equal([], found(user, changed_tags: "leaked_term"), label)
        assert_equal([], found(user, tag_matches: "*_term"), label)
      end

      FourierPostCreator.create!(post: @post, mxid: "@alice:41chan.net", recorded_by: @tunnel.id)
      creator = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => "@alice:41chan.net")
      moved = PostVersion.where(post_id: @post.id).order(:version, :id).redacting_private_tags_for(nil, creator).to_a.second
      assert_equal(%w[landscape moved_term], moved.tag_array, "the creator still reads it")
    end

    # The same for an add with no adder on record (UNKNOWN lineage), which the
    # cleanup never takes off: it stays on the public list, and in history.
    should "show a private tag the post still carries whatever its lineage" do
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape kept_term") }
      FourierTagSource.record_partition!(@post, { creator: ["kept_term"], auto: ["landscape"] }, @tunnel)
      @post.versions.first.update_columns(updater_id: nil) # rubocop:disable Rails/SkipsModelValidations

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        assert_equal(%w[kept_term landscape], history(user).first.tag_array.sort, label)
        assert_equal([@post.versions.first.id], found(user, changed_tags: "kept_term"), label)
      end
    end

    # The 2026-08-04..06 shape: the cleanup took the leak out of tag_string,
    # and an alias later moved the private row -- not the post, which no
    # longer carried the tag, so its history holds the leak only under the
    # name it had before.
    should "withhold a bot-leaked private tag under the name it had before an alias moved its row" do
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape leaked_term") }
      FourierTagSource.record_partition!(@post, { creator: ["leaked_term"], auto: ["landscape"] }, @tunnel)
      as(User.system) { @post.update!(tag_string: "landscape") }
      TagAlias.approve!(antecedent_name: "leaked_term", consequent_name: "moved_term", approver: @admin)
      assert_equal(2, @post.versions.count, "fixture: the alias did not touch the post")
      assert(FourierTagSource.exists?(post_id: @post.id, tag: "moved_term", public: false), "fixture: the alias moved the private row")

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        leaked, cleaned = history(user)
        assert_equal(["landscape"], leaked.tag_array, label)
        assert_equal([], cleaned.removed_tags, label)
        assert_equal([], found(user, changed_tags: "leaked_term"), label)
        assert_equal([], found(user, tag_matches: "leaked*"), label)
      end
    end

    # A rename leaves no alias (TagMover only), so its old name stays usable
    # and the autotagger can put it on a post the rename never touched. That
    # occurrence is the post's own public tag, not the private row's old
    # name: only one from before the move that took the old name away can be.
    should "not withhold a public tag a private row's name was once renamed from, added after the rename" do
      as(@member) { create(:post, tag_string: "old_x") }
      create_bur!("rename old_x -> new_x", @admin)
      assert_not(TagAlias.exists?(antecedent_name: "old_x"), "fixture: a rename is not an alias")
      travel(1.minute)
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape old_x") }
      FourierTagSource.record_partition!(@post, { creator: ["new_x"], auto: %w[landscape old_x] }, @tunnel)
      assert(FourierTagSource.exists?(post_id: @post.id, tag: "new_x", public: false), "fixture: the prompt's row is new_x, private")
      as(@member) { @post.update!(tag_string: "landscape") }

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        created, removed = history(user)
        assert_equal(%w[landscape old_x], created.tag_array, label)
        assert_equal(["old_x"], removed.removed_tags, label)
        assert_equal([created.id, removed.id].sort, found(user, changed_tags: "old_x"), label)
      end
    end

    # The archive merges an account's edits within the hour into one version
    # (MockPostSqsService#merge?), reckoning its added_tags against its own
    # earlier snapshot: the leak then sits in no version's added_tags at all,
    # only in a snapshot and in the cleanup's removed_tags.
    should "withhold a leak the archive merged out of every version's added tags" do
      PostVersion.sqs_service.unstub(:merge?)
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape leaked_term") }
      FourierTagSource.record_partition!(@post, { creator: ["leaked_term"], auto: ["landscape"] }, @tunnel)
      as(@tunnel) { @post.update!(tag_string: "landscape later_tag leaked_term") }
      as(User.system) { @post.update!(tag_string: "landscape later_tag") }
      assert_equal(2, @post.versions.count, "fixture: the bot's two edits are one version")
      assert_not(@post.versions.any? { |version| version.added_tags.include?("leaked_term") }, "fixture: no added_tags holds the leak")

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        assert_not_includes(history(user).map { |version| [version.tags, version.added_tags, version.removed_tags] }.to_json, "leaked_term", label)
        assert_equal([], found(user, changed_tags: "leaked_term"), label)
        assert_equal([], found(user, tag_matches: "leaked"), label)
      end
    end

    # fourier-tunnel publishes these on purpose whatever the prompt says
    # (FourierPrivateTagLineage::PUBLIC_LABELS), so no add of one is a leak.
    should "never withhold a label the posting bot publishes on purpose" do
      as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape no_train") }
      FourierTagSource.record_partition!(@post, { creator: ["no_train"], auto: ["landscape"] }, @tunnel)
      as(User.system) { @post.update!(tag_string: "landscape") }

      [nil, @viewer, @admin].each do |user|
        label = user&.level_string.inspect
        labelled, removed = history(user)
        assert_equal(%w[landscape no_train], labelled.tag_array, label)
        assert_equal(["no_train"], removed.removed_tags, label)
        assert_equal([labelled.id, removed.id].sort, found(user, changed_tags: "no_train"), label)
      end
    end

    # A pattern search walks the history of every post it could match. The
    # alias and rename lookups behind each walk (FourierPrivateTagLineage
    # move_pairs) are asked once for the whole search, never once per post.
    should "look aliases up the same number of times for a pattern search however many posts it walks" do
      leak = lambda do |name|
        as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape #{name}") }.tap do |post|
          FourierTagSource.record_partition!(post, { creator: [name], auto: ["landscape"] }, @tunnel)
          as(User.system) { post.update!(tag_string: "landscape cleaned_up") }
        end
      end
      lookups = lambda do
        sql = []
        count = ->(*, payload) { sql << payload[:sql] if payload[:sql].include?('"tag_aliases"') }
        shown = ActiveSupport::Notifications.subscribed(count, "sql.active_record") { PostVersion.search({ tag_matches: "leak_*" }, @viewer).to_a }
        assert_not_includes(shown.map(&:tags).join(" "), "leak_", "fixture: every leak is withheld")
        sql.size
      end

      leak.call("leak_one")
      one = lookups.call
      leak.call("leak_two")
      leak.call("leak_three")
      assert_equal(one, lookups.call)
    end
  end
end
