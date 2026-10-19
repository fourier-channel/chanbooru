require "test_helper"

class BulkUpdateRequestTest < ActiveSupport::TestCase
  context "for a bulk update request," do
    setup do
      @admin = create(:admin_user)
      CurrentUser.user = @admin
    end

    teardown do
      CurrentUser.user = nil
    end

    should_eventually "parse tags with tag type prefixes inside the script" do
      @bur = create(:bulk_update_request, script: "mass update aaa -> artist:bbb")
      assert_equal(%w[aaa bbb], @bur.tags)
    end

    context "when approving a BUR" do
      context "that has both implications and unimplications" do
        should "process them sequentially" do
          @bur = create_bur!("imply foo -> bar\nunimply foo -> bar", @admin)

          @ti = TagImplication.find_by(antecedent_name: "foo", consequent_name: "bar")
          assert_equal(true, @ti.present?)
          assert_equal(true, @ti.is_deleted?)
          assert_equal("approved", @bur.reload.status)
        end

        should "allow the flattening of an implication tree, ie (a -> b -> c) to (a -> c)" do
          @ti1 = create(:tag_implication, antecedent_name: "character_(costume)_(swimsuit)_(fate)", consequent_name: "character_(costume)_(fate)")
          @ti2 = create(:tag_implication, antecedent_name: "character_(costume)_(fate)", consequent_name: "character_(fate)")

          @script = <<~EOS
            unimply character_(costume)_(swimsuit)_(fate) -> character_(costume)_(fate)
            imply character_(costume)_(swimsuit)_(fate) -> character_(fate)
          EOS
          @bur = build(:bulk_update_request, script: @script)

          assert_equal(true, @bur.valid?)
          @bur.approve!(@admin)
          assert_equal("processing", @bur.reload.status)

          perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)
          assert_equal("approved", @bur.reload.status)

          assert_equal(true, @ti1.reload.is_deleted?)

          @ti = TagImplication.find_by(antecedent_name: "character_(costume)_(swimsuit)_(fate)", consequent_name: "character_(fate)")
          assert_equal(true, @ti.is_active?)
        end
      end

      context "that contains a mass update followed by an alias" do
        should "make the alias take effect after the mass update" do
          @p1 = create(:post, tag_string: "maid_dress")
          @p2 = create(:post, tag_string: "maid")

          @bur = create_bur!("mass update maid_dress -> maid dress\nalias maid_dress -> maid", @admin)

          assert_equal("dress maid", @p1.reload.tag_string)
          assert_equal("maid", @p2.reload.tag_string)
          assert_equal("approved", @bur.reload.status)
        end
      end

      context "that reverses an alias by removing and recreating it" do
        should "not fail with an alias conflict" do
          @ta = create(:tag_alias, antecedent_name: "rabbit", consequent_name: "bunny")
          @bur = create_bur!("unalias rabbit -> bunny\nalias bunny -> rabbit", @admin)

          assert_equal("deleted", @ta.reload.status)
          assert_equal("active", TagAlias.find_by(antecedent_name: "bunny", consequent_name: "rabbit").status)
          assert_equal("approved", @bur.reload.status)
        end
      end
    end

    context "when validating a script" do
      context "an unparseable script" do
        should "fail validation" do
          @script = <<~EOS
            create alias aaa -> 000
            create alias bbb > 111
            create alias ccc -> 222
          EOS

          assert_invalid_bur(
            script: @script,
            errors: ["Invalid line: create alias bbb > 111"],
          )
        end
      end

      context "a script with extra whitespace" do
        should "validate" do
          @script = %{
            create alias aaa -> 000

            create alias bbb -> 111
          }

          @bur = create(:bulk_update_request, script: @script)
          assert_equal(true, @bur.valid?)
        end
      end

      context "a bulk update request that is too long" do
        should "fail" do
          assert_invalid_bur(
            script: "nuke touhou\n" * 200,
            errors: ["Bulk update request is too long (maximum size: 100 lines). Split your request into smaller chunks and try again."],
          )
        end
      end

      context "a bulk update request with duplicate lines" do
        should "fail" do
          assert_invalid_bur(
            script: "imply a -> b\nimply a -> b\n",
            errors: ["Duplicate line found: create implication [[a]] -> [[b]]"],
          )
        end
      end
    end

    context "when the script is updated" do
      should "update the BUR's list of affected tags" do
        create(:tag_alias, antecedent_name: "ccc", consequent_name: "222")
        create(:tag_implication, antecedent_name: "ddd", consequent_name: "333")
        create(:tag, name: "iii")

        @script = <<~EOS
          create alias aaa -> 000
          create implication bbb -> 111
          remove alias ccc -> 222
          remove implication ddd -> 333
          mass update eee id:1 -fff ~ggg hhh* -> 444 -555
          category iii -> meta
        EOS

        @bur = create(:bulk_update_request, script: "create alias aaa -> bbb")
        assert_equal(%w[aaa bbb], @bur.tags)

        @bur.update!(script: @script)
        assert_equal(%w[000 111 222 333 444 555 aaa bbb ccc ddd eee fff ggg iii], @bur.tags)
      end
    end

    context "on approval" do
      setup do
        @post = create(:post, tag_string: "foo aaa")
        @script = '
          create alias foo -> bar
          create implication bar -> baz
          mass update aaa -> bbb blah
        '

        @bur = create_bur!(@script, @admin)

        @ta = TagAlias.where(antecedent_name: "foo", consequent_name: "bar").first
        @ti = TagImplication.where(antecedent_name: "bar", consequent_name: "baz").first
      end

      should "set the BUR approver" do
        assert_equal(@admin.id, @bur.approver.id)
      end

      should "create aliases/implications" do
        assert_equal("active", @ta.status)
        assert_equal("active", @ti.status)
      end

      should "process mass updates" do
        assert_equal("aaa bar baz bbb blah", @post.reload.tag_string)
      end

      should "set the alias/implication approvers" do
        assert_equal(@admin.id, @ta.approver.id)
        assert_equal(@admin.id, @ti.approver.id)
      end

      should "set the BUR as approved" do
        assert_equal("approved", @bur.reload.status)
      end

      should "update the post as DanbooruBot" do
        assert_equal(User.system, @post.versions.last.updater)
      end

      should "set the BUR as failed if there is an unexpected error during processing" do
        @bur = create(:bulk_update_request, script: "alias one -> two")
        TagAlias.any_instance.stubs(:process!).raises(RuntimeError.new("oh no"))

        assert_equal("pending", @bur.status)
        @bur.approve!(@admin)
        assert_equal("processing", @bur.status)

        assert_raises(RuntimeError) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }
        assert_equal("failed", @bur.reload.status)

        assert_equal("active", TagAlias.find_by!(antecedent_name: "one", consequent_name: "two").status)
        assert_equal("alias one -> two", @bur.script)
        assert_equal(@admin, @bur.approver)
      end
    end

    context "when a bulk update request fails" do
      should "allow it to be approved again" do
        @post = create(:post, tag_string: "foo aaa")
        @bur = create(:bulk_update_request, script: "alias foo -> bar")

        TagAlias.any_instance.stubs(:process!).raises(RuntimeError.new("oh no"))
        @bur.approve!(@admin)
        assert_raises(RuntimeError) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }

        assert_equal("aaa foo", @post.reload.tag_string)

        assert_equal("failed", @bur.reload.status)
        assert_not_nil(@bur.forum_topic)
        assert_equal(@admin, @bur.approver)

        @ta = TagAlias.find_by!(antecedent_name: "foo", consequent_name: "bar")
        assert_equal("active", @ta.status)
        assert_equal(@admin, @ta.approver)
        assert_equal(@bur.forum_topic, @ta.forum_topic)

        TagAlias.any_instance.unstub(:process!)
        @bur.approve!(@admin)
        perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)

        assert_equal("aaa bar", @post.reload.tag_string)

        assert_equal("approved", @bur.reload.status)
        assert_not_nil(@bur.forum_topic)
        assert_equal(@admin, @bur.approver)

        assert_equal("active", @ta.reload.status)
        assert_equal(@admin, @ta.approver)
        assert_equal(@bur.forum_topic, @ta.forum_topic)
      end
    end

    # Fork: a request keeps the record of its run (results), one entry a
    # line, numbered as the script has them: what each line did, what it
    # skipped and why, and the line a run stopped at. Upstream kept only a
    # status, so a run that skipped posts or failed halfway read the same as
    # one that did everything.
    context "the record of a run" do
      should "start empty" do
        assert_equal([], BulkUpdateRequest.new.results)
        assert_equal([], create(:bulk_update_request).reload.results)
      end

      should "record every line of a clean run" do
        @bur = create_bur!("create alias aaa -> bbb\n\nmass update ccc -> ddd", @admin)

        assert_equal("approved", @bur.reload.status)
        assert_equal([
          { "line" => 1, "command" => "create alias [[aaa]] -> [[bbb]]", "state" => "done", "matched" => nil, "skipped" => 0, "skipped_post_ids" => [], "skipped_reasons" => [], "error" => nil, "remedy" => nil },
          { "line" => 3, "command" => "mass update [[ccc]] -> [[ddd]]", "state" => "done", "matched" => 0, "skipped" => 0, "skipped_post_ids" => [], "skipped_reasons" => [], "error" => nil, "remedy" => nil },
        ], @bur.results)
        assert_equal(0, @bur.skipped_count)
        assert_nil(@bur.failed_line)
      end

      should "name the failed line, keep the lines before it, and run none after it" do
        BulkUpdateRequest::Command::MassUpdate.stubs(:mass_update).raises(RuntimeError.new("boom from 10.0.0.1"))
        @bur = create(:bulk_update_request, script: "create alias aaa -> bbb\nmass update foo -> bar\ncreate implication ccc -> ddd")
        @bur.approve!(@admin)
        assert_raises(RuntimeError) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }

        @bur.reload
        assert_equal("failed", @bur.status)
        assert_equal(%w[done failed not_run], @bur.results.pluck("state"))
        assert_equal(2, @bur.failed_line)
        failed = @bur.results.second
        assert_nil(failed["matched"])
        assert_match(/\ALine 2 /, failed["error"])
        assert_match(/approve this request again/, failed["remedy"])
        # The jobs pages are retired (a 404 to all but the owner): the
        # remedy names who can read the error, and where.
        assert_match(/the site owner can read the full error in the server log/, failed["remedy"])
        assert_no_match(/job log/, failed["remedy"])
        # Words only: never the raw exception, its class or an address.
        assert_no_match(/boom|10\.0\.0\.1|RuntimeError/, @bur.results.to_json)
        assert_equal(true, TagAlias.active.exists?(antecedent_name: "aaa", consequent_name: "bbb"))
        assert_equal(false, TagImplication.exists?(antecedent_name: "ccc", consequent_name: "ddd"))
      end

      should "name the failed line in the words of the record that refused" do
        create(:post, tag_string: "cute")
        create(:wiki_page, title: "cute", body: "a cute thing")
        @bur = create(:bulk_update_request, script: "convert cute -> pool:123")
        @bur.approve!(@admin)
        assert_raises(ActiveRecord::RecordInvalid) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }

        assert_equal(1, @bur.reload.failed_line)
        assert_equal("Line 1 stopped: Name cannot contain only digits.", @bur.results.first["error"])
      end

      should "go on past a line that skipped posts, and end partial" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("update foo -> parent:#{@post.id}\ncreate alias xx -> yy", @admin)

        assert_equal("partial", @bur.reload.status)
        assert_equal(%w[skipped_some done], @bur.results.pluck("state"))
        assert_match(/approve this request again/, @bur.results.first["remedy"])
        assert_equal(1, @bur.skipped_count)
        assert_nil(@bur.failed_line)
        assert_equal(true, TagAlias.active.exists?(antecedent_name: "xx", consequent_name: "yy"))
      end

      should "keep at most 1,000 skipped ids a line, count every skip, and give every skip a reason" do
        skips = (1..1500).map { |id| { post_id: id, reasons: [] } }
        BulkUpdateRequest::Command::MassUpdate.stubs(:mass_update).returns({ matched: 1500, skipped: skips })
        @bur = create_bur!("mass update foo -> bar", @admin)

        line = @bur.reload.results.first
        assert_equal(1500, line["skipped"])
        assert_equal((1..1000).to_a, line["skipped_post_ids"])
        assert_equal([{ "message" => "The post could not be saved, and gave no reason", "count" => 1500 }], line["skipped_reasons"])
      end

      should "clear the previous run's record when approved again" do
        TagAlias.any_instance.stubs(:process!).raises(RuntimeError.new("oh no"))
        @bur = create(:bulk_update_request, script: "alias foo -> bar")
        @bur.approve!(@admin)
        assert_raises(RuntimeError) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }
        assert_equal(["failed"], @bur.reload.results.pluck("state"))

        TagAlias.any_instance.unstub(:process!)
        @bur.approve!(@admin)
        assert_equal([], @bur.reload.results)
        perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)

        assert_equal("approved", @bur.reload.status)
        assert_equal(["done"], @bur.results.pluck("state"))
      end

      should "let a partial request be approved again, and run it again" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("alias aaa -> bbb\nupdate foo -> parent:#{@post.id}", @admin)
        assert_equal("partial", @bur.reload.status)

        @post.update!(tag_string: "qux")
        @bur.approve!(@admin)
        perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)

        assert_equal("approved", @bur.reload.status)
        assert_equal(%w[done done], @bur.results.pluck("state"))
      end

      # A partial run reached the end of the script, so its implications
      # are active: approving it again must not be refused for them.
      should "let a partial request whose implication already ran be approved again" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("imply ccc -> ddd\nupdate foo -> parent:#{@post.id}", @admin)
        assert_equal("partial", @bur.reload.status)
        assert_equal(true, TagImplication.active.exists?(antecedent_name: "ccc", consequent_name: "ddd"))

        @post.update!(tag_string: "qux")
        @bur.approve!(@admin)
        perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)

        assert_equal("approved", @bur.reload.status)
        assert_equal(%w[done done], @bur.results.pluck("state"))
        assert_equal(1, TagImplication.where(antecedent_name: "ccc", consequent_name: "ddd").count)
      end

      # Lines after a failure did not run, so nothing was counted for them.
      should "count nothing on the lines a failure kept from running" do
        BulkUpdateRequest::Command::MassUpdate.stubs(:mass_update).raises(RuntimeError.new("boom"))
        @bur = create(:bulk_update_request, script: "mass update foo -> bar\ncreate implication ccc -> ddd")
        @bur.approve!(@admin)
        assert_raises(RuntimeError) { perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob) }

        not_run = @bur.reload.results.second
        assert_equal("not_run", not_run["state"])
        assert_nil(not_run["matched"])
        assert_nil(not_run["skipped"])
      end

      # The record describes the script that ran. Once the script is
      # edited its line numbers and commands no longer match, and a command
      # it holds may name a tag the edit took out of `tags` (NamesTags
      # judges a row by `tags` alone), so the edit clears it.
      should "clear the record when the script is edited" do
        @post = create(:post, tag_string: "foo")
        @bur = create_bur!("alias aaa -> bbb\nupdate foo -> parent:#{@post.id}", @admin)
        assert_equal("partial", @bur.reload.status)
        assert_equal(2, @bur.results.size)

        @bur.update!(status: "partial") # no script change: the record stays
        assert_equal(2, @bur.reload.results.size)

        CurrentUser.scoped(@admin) { @bur.update!(script: "update foo -> qux") }
        @bur.reload
        assert_equal([], @bur.results)
        assert_equal([[], 0, nil], [@bur.lines, @bur.skipped_count, @bur.failed_line])
        assert_equal("partial", @bur.status)
      end

      # A reason may embed a post (!post #N), checked as it is filed. The
      # post can be rerated afterwards; that must not stop the request from
      # being approved, run or rejected, which all save it again.
      should "approve, run and reject a request whose reason embeds a post rerated since" do
        post = create(:post, rating: "s")
        approved = create(:bulk_update_request, script: "create alias aaa -> bbb", reason: "see\n\n!post ##{post.id}")
        rejected = create(:bulk_update_request, script: "create alias ccc -> ddd", reason: "see\n\n!post ##{post.id}")
        post.update_columns(rating: "e") # rubocop:disable Rails/SkipsModelValidations

        approved.reload.approve!(@admin)
        perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)
        rejected.reload.reject!(@admin)

        assert_equal("approved", approved.reload.status)
        assert_equal("rejected", rejected.reload.status)
        # Still refused when it is filed.
        filed = build(:bulk_update_request, script: "create alias eee -> fff", reason: "see\n\n!post ##{post.id}")
        assert_equal(false, filed.valid?)
        assert_equal(["Reason can't include NSFW images"], filed.errors.full_messages)
      end

      should "count a partial request approvable again, and an approved or processing one not" do
        assert_equal(true, Pundit.policy!(@admin, create(:bulk_update_request, status: "partial")).approve?)
        assert_equal(false, Pundit.policy!(@admin, create(:bulk_update_request, status: "approved")).approve?)
        assert_equal(false, Pundit.policy!(@admin, create(:bulk_update_request, status: "processing")).approve?)
      end
    end

    should "create a forum topic" do
      user = create(:user)
      bur = create(:bulk_update_request, user: user, reason: "zzz", script: "create alias aaa -> bbb")

      assert_equal(true, bur.forum_post.present?)
      assert_match(/\[bur:#{bur.id}\]/, bur.forum_post.body)
      assert_match(/zzz/, bur.forum_post.body)
      assert_equal(user, bur.forum_topic.creator)
      assert_equal(user, bur.forum_topic.updater)
      assert_equal(user, bur.forum_post.creator)
      assert_equal(user, bur.forum_post.updater)
      # Fork: the reason is kept on the request too, forum or no forum.
      assert_equal("zzz", BulkUpdateRequest.find(bur.id).reason)
    end

    # Fork: while the forum is retired (Danbooru.config.retired_sections,
    # FourierRetiredSections) a request opens no topic -- its link would be a
    # 404 to everyone but the owner -- and keeps its reason on itself. The
    # test env retires nothing, so the inherited tests above measure upstream;
    # this context switches the forum off.
    context "while the forum is retired" do
      setup do
        Danbooru.config.stubs(:retired_sections).returns(%w[forum_topics forum_posts forum_post_votes forum_topic_visits])
      end

      should "create no forum topic and no forum post" do
        assert_no_difference(["ForumTopic.count", "ForumPost.count"]) do
          @bur = create(:bulk_update_request, reason: "zzz")
        end

        assert_nil(@bur.forum_topic)
        assert_nil(@bur.forum_post)
      end

      should "keep the reason on the request" do
        bur = create(:bulk_update_request, reason: "zzz")

        assert_equal("zzz", BulkUpdateRequest.find(bur.id).reason)
        assert_equal(:text, BulkUpdateRequest.columns_hash["reason"]&.type)
        assert_equal(true, BulkUpdateRequest.columns_hash["reason"]&.null)
      end

      should "not require a title" do
        assert_equal(true, build(:bulk_update_request, title: nil).valid?)
      end

      should "refuse a forum topic or post, and say what to do" do
        message = "Forum topics are retired on this site, so a request cannot be attached to one. Send the request without forum_topic_id or forum_post_id"
        topic = create(:forum_topic)
        bur = build(:bulk_update_request, forum_topic: topic)

        assert_equal(false, bur.valid?)
        assert_equal([message], bur.errors.full_messages)

        bur = create(:bulk_update_request)
        assert_equal(false, bur.update(forum_post: create(:forum_post, topic: topic)))
        assert_equal([message], bur.errors.full_messages)
        assert_nil(BulkUpdateRequest.find(bur.id).forum_post_id)
      end

      should "be approved, processed and rejected with no forum topic" do
        approved = create(:bulk_update_request, script: "create alias aaa -> bbb")
        rejected = create(:bulk_update_request, script: "create alias ccc -> ddd")

        assert_no_difference(["ForumTopic.count", "ForumPost.count"]) do
          approved.approve!(@admin)
          perform_enqueued_jobs(only: ProcessBulkUpdateRequestJob)
          rejected.reject!(@admin)
        end

        assert_equal("approved", approved.reload.status)
        assert_equal("active", TagAlias.find_by!(antecedent_name: "aaa", consequent_name: "bbb").status)
        assert_equal("rejected", rejected.reload.status)
      end
    end

    context "with an associated forum topic" do
      setup do
        @topic = create(:forum_topic, title: "[bulk] hoge", creator: @admin)
        @post = create(:forum_post, topic: @topic, creator: @admin)
        @req = create(:bulk_update_request, script: "create alias AAA -> BBB", forum_topic: @topic, forum_post: @post)
      end

      # Fork: replaces upstream's "leave the BUR pending if there is a
      # validation error during approval", which stubbed update! and never
      # called approve! -- it passed with approve! deleted.
      should "refuse approval with Processor::Error and leave the BUR pending when a line no longer validates" do
        create(:tag_alias, antecedent_name: "bbb", consequent_name: "ccc")

        assert_no_enqueued_jobs(only: ProcessBulkUpdateRequestJob) do
          assert_no_difference(-> { @topic.forum_posts.count }) do
            error = assert_raises(BulkUpdateRequest::Processor::Error) { @req.approve!(@admin) }
            assert_match(/bbb is already aliased to ccc/, error.message)
            assert_match(/Fix:/, error.message)
            assert_equal([{ line: 1, text: "create alias AAA -> BBB", reason: "Can't create alias [[aaa]] -> [[bbb]] (bbb is already aliased to ccc)" }], error.errors)
          end
        end

        @req = BulkUpdateRequest.find(@req.id)
        assert_equal("pending", @req.status)
        assert_nil(@req.approver_id)
      end

      should "approve after the cause is fixed (the refusal is not sticky)" do
        conflict = create(:tag_alias, antecedent_name: "bbb", consequent_name: "ccc")
        assert_raises(BulkUpdateRequest::Processor::Error) { @req.approve!(@admin) }

        conflict.update!(status: "deleted")
        @req = BulkUpdateRequest.find(@req.id)
        assert_enqueued_jobs(1, only: ProcessBulkUpdateRequestJob) { @req.approve!(@admin) }
        assert_equal("processing", @req.reload.status)
      end

      should "leave the BUR pending if there is an unexpected error during approval" do
        @req.forum_updater.stubs(:update).raises(RuntimeError.new("blah"))
        assert_raises(RuntimeError) { @req.approve!(@admin) }

        # XXX Raises "Couldn't find BulkUpdateRequest without an ID". Possible
        # rails bug? (cf rails #34637, #34504, #30167, #15018).
        # @req.reload

        @req = BulkUpdateRequest.find(@req.id)
        assert_equal("pending", @req.status)
      end

      should "create a forum post on approval" do
        @req.approve!(@admin)

        assert_equal("processing", @req.status)
        assert_equal(%{The "bulk update request ##{@req.id}":/bulk_update_requests?search%5Bid%5D=#{@req.id} (forum ##{@post.id}) has been approved by @#{@admin.name}.}, @topic.forum_posts.last.body)
        assert_equal(User.system, @topic.forum_posts.last.creator)
        assert_equal(User.system, @topic.forum_posts.last.updater)
      end

      should "not send @mention dmails to the approver" do
        assert_no_difference("Dmail.count") do
          @req.approve!(@admin)
        end
      end
    end

    context "that doesn't belong to a forum post" do
      should "not fail to be rejected" do
        bur = create(:bulk_update_request)
        bur.update!(forum_post: nil)

        assert_nil(bur.forum_post)
        bur.reject!

        assert_equal("rejected", bur.status)
      end

      should "not fail to be approved" do
        bur = create(:bulk_update_request)
        bur.update!(forum_post: nil)

        assert_nil(bur.forum_post)
        bur.approve!(create(:admin_user))

        assert_equal("processing", bur.status)
      end
    end

    context "when validating a new bulk update request" do
      subject { build(:bulk_update_request) }

      should allow_value("test").for(:title)
      should_not allow_value("").for(:title)
      should_not allow_value(" ").for(:title)
      should_not allow_value("x" * 201).for(:title)

      should allow_value("test").for(:reason)
      should allow_value((["!post #1"] * 5).join("\n")).for(:reason)
      should_not allow_value("").for(:reason)
      should_not allow_value(" ").for(:reason)
      should_not allow_value("x" * 20_001).for(:reason)
      should_not allow_value((["!post #1"] * 10).join("\n")).for(:reason)

      should_not allow_value(0).for(:status)
      should_not allow_value("unknown").for(:status)

      should allow_value("nuke fumimi").for(:reason)
      should_not allow_value("").for(:script)
      should_not allow_value("x" * 20_001).for(:script)
    end

    context "when searching" do
      setup do
        @bur1 = create(:bulk_update_request, title: "foo", script: "create alias aaa -> bbb", user: @admin, approver: @admin, status: "approved")
        @bur2 = create(:bulk_update_request, title: "bar", script: "create implication bbb -> ccc", user: @admin)
      end

      should "work" do
        assert_search_equals(@bur1, user_name: @admin.name, approver_name: @admin.name, status: "approved")
      end

      context "by score" do
        setup do
          @user1 = create(:user)
          @user2 = create(:user)
          @user3 = create(:user)
          create(:forum_post_vote, forum_post: @bur1.forum_post, creator: @user1, score: 1)
          create(:forum_post_vote, forum_post: @bur1.forum_post, creator: @user2, score: 1)
          create(:forum_post_vote, forum_post: @bur2.forum_post, creator: @user3, score: -1)
        end

        should "filter by exact score" do
          assert_search_equals(@bur1, score: "2")
          assert_search_equals(@bur2, score: "-1")
        end

        should "filter by score greater than" do
          assert_search_equals(@bur1, score: ">0")
        end

        should "filter by score less than" do
          assert_search_equals(@bur2, score: "<0")
        end

        should "order by score descending" do
          assert_search_equals([@bur1, @bur2], order: "score_desc")
        end

        should "order by score ascending" do
          assert_search_equals([@bur2, @bur1], order: "score_asc")
        end

        should "search and order by score" do
          assert_search_equals([@bur2, @bur1], order: "score_asc", score: ">-20")
        end
      end

      context "by can_approve" do
        setup do
          @artist_tag = create(:artist_tag, name: "some_artist", post_count: 10)
          @character_tag1 = create(:character_tag, name: "some_character", post_count: 50)
          @character_tag2 = create(:character_tag, name: "another_character", post_count: 100)
          create(:wiki_page, title: @character_tag1.name)
          create(:wiki_page, title: @character_tag2.name)

          @builder = create(:builder_user)
          @mod = create(:mod_user)

          @bur3 = create(:bulk_update_request, script: "create alias #{@artist_tag.name} -> some_other_artist")

          @bur4 = create(:bulk_update_request, script: "create implication #{@character_tag1.name} -> #{@character_tag2.name}")
        end

        should "find BURs the user can approve" do
          assert_search_equals(@bur3, can_approve: "true", current_user: @builder)
          assert_search_equals([@bur3, @bur4], can_approve: "true", current_user: @mod, order: "id_asc")
          assert_search_equals([@bur2, @bur3, @bur4], can_approve: "true", current_user: @admin, order: "id_asc")
        end

        should "find BURs the user can't approve" do
          assert_search_equals([@bur2, @bur4], can_approve: "false", current_user: @builder, order: "id_asc")
          assert_search_equals(@bur2, can_approve: "false", current_user: @mod)
          assert_search_equals([], can_approve: "false", current_user: @admin)
        end

        should "exclude BURs that aren't pending" do
          assert_not_includes(BulkUpdateRequest.search({ can_approve: "true" }, @admin).ids, @bur1.id)
          assert_not_includes(BulkUpdateRequest.search({ can_approve: "false" }, @admin).ids, @bur1.id)
        end
      end
    end
  end
end
