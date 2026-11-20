# frozen_string_literal: true

require "test_helper"

# R1 (operator 2026-11-20) at the doors the posting bots write through: the
# tag-source routes, the creator record, the generation-metadata store, and
# the moderation pill's second look under its lock. Each one let a writer
# past a post hidden from it -- the pipeline wholesale, or anyone between the
# check and the lock -- and the write answered for the post (review
# 2026-11-20, findings 3-8).
#
# Of the pipeline, sample (an approver) still writes a deleted post it
# cannot see; tunnel (a builder) writes its own uploads and nothing else that
# is hidden from it. Deleted-post visibility and the banished-post rule are
# relaxed under test, so both are stubbed to the production shape, and every
# refusal first asserts the post really is hidden from the writer.
class HiddenPostBotDoorsTest < ActionDispatch::IntegrationTest
  CREATOR = "@alice:41chan.net"

  context "With deleted posts hidden as in production" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!
      UploadLimit.any_instance.stubs(:limited?).returns(false)

      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @tunnel = create(:builder_user, name: "tunnel")
      @builder = create(:builder_user)
      @uploader = create(:contributor_user)

      @deleted = as(@uploader) { create(:post, uploader: @uploader, md5: SecureRandom.hex(16), tag_string: "a b", source: "mxc://41chan.net/r1_deleted") }
      @deleted.delete!("ordinary deletion", user: @admin)
      @own = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "a b") }
      @own.delete!("ordinary deletion", user: @admin)
      @live = as(@uploader) { create(:post, uploader: @uploader, md5: SecureRandom.hex(16), tag_string: "a b") }
      [@deleted, @own].each(&:reload)

      assert TagBanishment.pipeline?(@tunnel) && TagBanishment.pipeline?(@sample), "fixture: both bots are the pipeline"
      assert @deleted.hidden_from?(@tunnel), "fixture: hidden from tunnel"
      assert @deleted.hidden_from?(@sample), "fixture: hidden from sample"
      assert @deleted.hidden_from?(@builder), "fixture: hidden from a builder"
      assert_not @own.hidden_from?(@tunnel), "fixture: tunnel sees its own deletion"
    end

    context "POST /posts/:post_id/tag_sources" do
      should "refuse tunnel a deleted post it did not upload as not found, recording nothing" do
        post_auth "/posts/#{@deleted.id}/tag_sources.json", @tunnel, as: :json, params: { auto: %w[a b] }

        assert_response 404, response.body.to_s[0,600]
        assert_not FourierTagSource.exists?(post_id: @deleted.id)
      end

      should "answer tunnel's mxc for it exactly as for a post that does not exist" do
        answers = [@deleted.id, 0].map do |id|
          post_auth "/posts/#{id}/tag_sources.json", @tunnel, as: :json, params: { mxc: "mxc://41chan.net/r1_dup" }
          [response.status, response.parsed_body.except("post_id")]
        end

        assert_equal({ "accepted" => false, "reason" => "no_such_post" }, answers.first.last["mxc"])
        assert_equal answers.last, answers.first
        assert_not PostMxc.exists?(mxc: "mxc://41chan.net/r1_dup")
      end

      # models inserts an auto row for a tag the post carries and has no row
      # for, so a post it wrote would have one.
      should "count it missing for models, inserting nothing" do
        post_auth fourier_tag_source_models_path(format: :json), @tunnel, as: :json, params: { posts: [{ post_id: @deleted.id, hydra: %w[a] }, { post_id: @live.id, hydra: %w[a] }] }

        assert_response :success
        assert_equal [@deleted.id], response.parsed_body["missing_posts"]
        assert_not FourierTagSource.exists?(post_id: @deleted.id)
        assert FourierTagSource.exists?(post_id: @live.id, tag: "a"), "control: the live post took its row"
      end

      # Controls: the writers R1 leaves alone.
      should "let tunnel write its own deleted upload" do
        post_auth "/posts/#{@own.id}/tag_sources.json", @tunnel, as: :json, params: { auto: %w[a b], mxc: "mxc://41chan.net/r1_own" }

        assert_response :success
        assert_equal({ "accepted" => true }, response.parsed_body["mxc"])
        assert FourierTagSource.exists?(post_id: @own.id)
      end

      should "let sample, an approver in the pipeline, write a deleted post it cannot see" do
        post_auth "/posts/#{@deleted.id}/tag_sources.json", @sample, as: :json, params: { auto: %w[a b], mxc: "mxc://41chan.net/r1_sample" }

        assert_response :success
        assert_equal({ "accepted" => true }, response.parsed_body["mxc"])
        assert FourierTagSource.exists?(post_id: @deleted.id)
      end
    end

    context "POST /fourier/posts/:post_id/creator" do
      should "refuse tunnel a deleted post it did not upload exactly as a missing one" do
        answers = [@deleted.id, 0].map do |id|
          post_auth "/fourier/posts/#{id}/creator.json", @tunnel, as: :json, params: { mxid: CREATOR }
          body = response.parsed_body
          [response.status, body.merge("error" => body["error"].to_s.sub(id.to_s, "ID"))]
        end

        assert_equal 404, answers.first.first
        assert_equal answers.last, answers.first
        assert_not FourierPostCreator.exists?(post_id: @deleted.id)
      end

      should "record tunnel's own deleted upload" do
        post_auth "/fourier/posts/#{@own.id}/creator.json", @tunnel, as: :json, params: { mxid: CREATOR }

        assert_response :success
        assert_equal CREATOR, FourierPostCreator.find_by!(post_id: @own.id).mxid
      end
    end

    context "POST /fourier/generation_metadata" do
      setup do
        @raw_md5 = SecureRandom.hex(16)
        @fields = { "png:parameters" => "kept text" }
        @record = FourierGenerationMetadata.create!(md5: @deleted.md5, raw_md5: @raw_md5, source: "matrix", poster: CREATOR, fields: @fields)
      end

      should "refuse a re-send for a hidden post's md5 as not found, changing nothing" do
        post_auth "/fourier/generation_metadata.json", @builder, as: :json,
          params: { md5: @deleted.md5, raw_md5: @raw_md5, source: "matrix", poster: CREATOR, fields: { "png:parameters" => "replaced" } }

        assert_response 404, response.body.to_s[0,600]
        assert_equal @fields, @record.reload.fields
      end

      should "refuse a send whose original is filed under a hidden post as not found, never naming its md5" do
        md5 = SecureRandom.hex(16)
        post_auth "/fourier/generation_metadata.json", @builder, as: :json,
          params: { md5: md5, raw_md5: @raw_md5, source: "matrix", poster: CREATOR, fields: { "png:parameters" => "x" } }

        assert_response 404, response.body.to_s[0,600]
        assert_not_includes response.body, @deleted.md5
        assert_not FourierGenerationMetadata.exists?(md5: md5)
      end

      # Nothing filed yet: the create path was not asked at all (review
      # 2026-11-20), so a first send filed a row for a post hidden from the
      # sender, under its md5 or naming it as the original.
      should "refuse a first send for a hidden post as not found, filing nothing" do
        @record.destroy!
        [{ md5: @deleted.md5, raw_md5: SecureRandom.hex(16) }, { md5: SecureRandom.hex(16), raw_md5: @deleted.md5 }].each do |sent|
          post_auth "/fourier/generation_metadata.json", @builder, as: :json,
            params: sent.merge(source: "matrix", poster: CREATOR, fields: { "png:parameters" => "x" })

          assert_response 404, sent.inspect
          assert_not FourierGenerationMetadata.exists?(md5: sent[:md5]), sent.inspect
        end
      end

      should "file a first send for a post the sender sees" do
        post_auth "/fourier/generation_metadata.json", @builder, as: :json,
          params: { md5: @live.md5, raw_md5: SecureRandom.hex(16), source: "matrix", poster: CREATOR, fields: { "png:parameters" => "x" } }

        assert_response :success
        assert FourierGenerationMetadata.exists?(md5: @live.md5)
      end

      should "still answer 409 naming the md5 when the original is filed under a post the sender sees" do
        @record.update_columns(md5: @live.md5)
        post_auth "/fourier/generation_metadata.json", @builder, as: :json,
          params: { md5: SecureRandom.hex(16), raw_md5: @raw_md5, source: "matrix", poster: CREATOR, fields: { "png:parameters" => "x" } }

        assert_response 409
        assert_equal "raw_md5_conflict", response.parsed_body["reason"]
        assert_includes response.body, @live.md5
      end
    end

    # A write door finds the post writable, then takes the row lock: a post
    # hidden in between (deleted by someone else) was written all the same.
    # The deletion lands inside the door's own lock!, after the find and the
    # authorize passed, which is that race with its timing pinned. It lands
    # in the door's transaction, so the refusal rolls it back with the rest:
    # @hidden_at_lock records that the post was hidden from the writer when
    # the lock was taken.
    context "A post hidden between the find and the lock" do
      setup do
        admin = @admin
        hidden_at_lock = @hidden_at_lock = []
        @racing = Post.find(@live.id)
        @racing.define_singleton_method(:lock!) do |*args, **kwargs|
          Post.find(id).delete!("deleted in between", user: admin)
          super(*args, **kwargs).tap { hidden_at_lock << CurrentUser.user.then { |user| [user.id, hidden_from?(user)] } }
        end
        Post.stubs(:find_writable!).returns(@racing)
      end

      should "not be jailed by the moderation pill" do
        moderator = create(:moderator_user)
        login_as(moderator)

        patch modulation_moderation_path(@live), params: { jail: true }, as: :json

        assert_response 404
        assert_equal [[moderator.id, true]], @hidden_at_lock, "fixture: hidden from the moderator under the lock"
        assert_not @live.reload.has_tag?("troll_jail")
        assert_not ModAction.exists?(subject: @live, category: "post_jail")
      end

      should "not take a builder's tag edit" do
        put_auth post_path(@live, format: :json), @builder, params: { post: { tag_string: "a b raced" } }

        assert_response 404
        assert_equal [[@builder.id, true]], @hidden_at_lock, "fixture: hidden from the builder under the lock"
        assert_not_includes @live.reload.tag_array, "raced"
      end
    end
  end
end
