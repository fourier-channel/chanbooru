require "test_helper"

class MassUpdateCommandTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin_user)
    CurrentUser.user = @admin
  end

  teardown do
    CurrentUser.user = nil
  end

  context "the mass update command" do
    context "on creation" do
      should "not allow invalid searches in mass updates" do
        assert_invalid_bur(
          script: "mass update (foo -> bar",
          errors: ["Can't mass update {{(foo}} -> {{bar}} (the search {{(foo}} has a syntax error)"],
        )
      end

      should "render simple tags as wiki links in dtext" do
        @bur = build(:bulk_update_request, script: "mass update bunny_ears -> rabbit_ears")
        create(:tag_alias, consequent_name: "bunny_ears", antecedent_name: "rabbit_ears")

        assert_equal("mass update [[bunny_ears]] -> [[rabbit_ears]]", @bur.processor.to_dtext)
      end

      should "render complex queries as search links in dtext" do
        @bur = build(:bulk_update_request, script: "mass update source:imageboard -> source:Imageboard")

        assert_equal("mass update {{source:imageboard}} -> {{source:Imageboard}}", @bur.processor.to_dtext)
      end
    end

    context "on approval" do
      should "update the tags" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("mass update foo -> bar baz", @admin)

        assert_equal("bar baz foo", @post.reload.tag_string)
        assert_equal("approved", @bur.reload.status)
        assert_equal(User.system, @post.versions.last.updater)
      end

      should "be case-sensitive" do
        @post = create(:post, source: "imageboard")
        @bur = create_bur!("mass update source:imageboard -> source:Imageboard", @admin)

        assert_equal("Imageboard", @post.reload.source)
        assert_equal("approved", @bur.reload.status)
      end

      should "not raise a validation error for updates containing nonexisting pools" do
        @bur = create_bur!("update pool:123 -> test", @admin)

        assert_equal("approved", @bur.reload.status)
      end

      # Fork: a post that refuses the edit (its save fails validation) is
      # skipped, every other post is updated, and the skip is logged,
      # counted and named on the request -- upstream dropped save's answer
      # and called the request approved.
      should "skip a post that fails validation, update the rest and report it" do
        @p1 = create(:post, tag_string: "foo")
        @p2 = create(:post, tag_string: "foo")
        @bur = create_bur!("update foo -> parent:#{@p1.id}", @admin)

        assert_equal(@p1.id, @p2.reload.parent_id)
        assert_nil(@p1.reload.parent_id)
        assert_equal("partial", @bur.reload.status)
        line = @bur.results.first
        assert_equal("skipped_some", line["state"])
        assert_equal(2, line["matched"])
        assert_equal(1, line["skipped"])
        assert_equal([@p1.id], line["skipped_post_ids"])
        assert_equal([{ "message" => "Post cannot have itself as a parent", "count" => 1 }], line["skipped_reasons"])
      end

      should "log each skipped post with its reason" do
        @post = create(:post, tag_string: "foo")
        DanbooruLogger.stubs(:info)
        DanbooruLogger.expects(:info).with { |message, *| message.include?("post ##{@post.id}: skipped by mass update") && message.include?("Post cannot have itself as a parent") }

        create_bur!("update foo -> parent:#{@post.id}", @admin)
      end

      # Fork: a post can save and still leave out part of the edit -- a
      # deprecated tag is not added, a tag an implication holds is not
      # removed; Post only warns (added_tags_are_valid,
      # removed_tags_are_valid). That post did not take the edit, so it is
      # skipped too, in Post's own words.
      should "skip a post that saved without a deprecated tag it was given" do
        @post = create(:post, tag_string: "foo")
        create(:tag, name: "dep").update_columns(is_deprecated: true) # rubocop:disable Rails/SkipsModelValidations
        @bur = create_bur!("update foo -> dep", @admin)

        assert_equal("foo", @post.reload.tag_string)
        assert_equal("partial", @bur.reload.status)
        line = @bur.results.first
        assert_equal(["skipped_some", 1, 1, [@post.id]], line.values_at("state", "matched", "skipped", "skipped_post_ids"))
        assert_equal([{ "message" => "The following tags are deprecated and could not be added: [[dep]]", "count" => 1 }], line["skipped_reasons"])
      end

      should "skip a post that saved with a tag an implication holds on it" do
        create(:tag_implication, antecedent_name: "baz", consequent_name: "bar")
        @post = create(:post, tag_string: "foo baz")
        assert_includes(@post.tag_array, "bar")
        @bur = create_bur!("update foo -> -bar", @admin)

        assert_includes(@post.reload.tag_array, "bar")
        assert_equal("partial", @bur.reload.status)
        assert_equal([{ "message" => "[[bar]] could not be removed. Check for implications and try again", "count" => 1 }], @bur.results.first["skipped_reasons"])
      end

      should "skip a post that took only part of the edit, and keep the part it took" do
        @post = create(:post, tag_string: "foo")
        create(:tag, name: "dep").update_columns(is_deprecated: true) # rubocop:disable Rails/SkipsModelValidations
        @bur = create_bur!("update foo -> dep qux", @admin)

        assert_equal("foo qux", @post.reload.tag_string)
        assert_equal("partial", @bur.reload.status)
        assert_equal([@post.id], @bur.results.first["skipped_post_ids"])
        assert_match(/only part of the edit/, @bur.results.first["remedy"])
      end

      should "not count a post as skipped for a tag the edit created or one it already had" do
        @post = create(:post, tag_string: "foo bar")
        @bur = create_bur!("update foo -> bar brand_new_tag", @admin)

        assert_equal("bar brand_new_tag foo", @post.reload.tag_string)
        assert_equal("approved", @bur.reload.status)
        assert_equal([["done", 1, 0]], @bur.results.map { |line| line.values_at("state", "matched", "skipped") })
      end

      should "stay approved and report nothing skipped when every post saves" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("mass update foo -> bar baz", @admin)

        assert_equal("approved", @bur.reload.status)
        assert_equal([["done", 1, 0]], @bur.results.map { |line| line.values_at("state", "matched", "skipped") })
      end
    end

    # Fork: the block runs on pool threads outside a transaction
    # (ApplicationRecord.parallel_find_each), so the skips are collected
    # into a thread-safe list.
    context "run from several threads" do
      should "keep every skip" do
        posts = create_list(:post, 10, tag_string: "foo")
        threads = Concurrent::Set.new
        # A transactional test holds a transaction open, which sends
        # parallel_find_each down its serial path: say none is open, and stub
        # the lock and the save so no thread touches the shared connection.
        # Each save takes 20 ms, so the pool hands the posts to several threads.
        Post.connection.stubs(:transaction_open?).returns(false)
        Post.any_instance.stubs(:with_lock).yields
        Post.any_instance.stubs(:save).with { (threads << Thread.current) && sleep(0.02) }.returns(false)

        result = BulkUpdateRequest::Command::MassUpdate.mass_update("foo", "bar")

        assert_operator(threads.size, :>, 1)
        assert_equal(10, result[:matched])
        assert_equal(posts.map(&:id).sort, result[:skipped].pluck(:post_id).sort)
      end
    end
  end
end
