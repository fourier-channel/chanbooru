require "test_helper"

class NukeCommandTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin_user)
    CurrentUser.user = @admin
  end

  teardown do
    CurrentUser.user = nil
  end

  context "the nuke command" do
    context "on creation" do
      should "raise an error when trying to nuke a pool that doesn't exist (by name)" do
        assert_invalid_bur(
          script: "nuke pool:mario_quest",
          errors: ["Can't nuke {{pool:mario_quest}} (pool doesn't exist)"],
        )
      end

      should "raise an error when trying to nuke a pool that doesn't exist (by ID)" do
        assert_invalid_bur(
          script: "nuke pool:12345678",
          errors: ["Can't nuke {{pool:12345678}} (pool doesn't exist)"],
        )
      end
    end

    context "on approval" do
      should "remove tags" do
        @post = create(:post, tag_string: "foo bar")
        @bur = create_bur!("nuke bar", @admin)

        assert_equal("foo", @post.reload.tag_string)
        assert_equal("approved", @bur.reload.status)
        assert_equal(User.system, @post.versions.last.updater)
      end

      # Fork: provenance rows are never deleted on a removal (a removed tag's
      # row is simply not drawn, FourierTagSource.buckets_and_lamps_for), so
      # a revert brings the tag back with where it came from. A guard against
      # a future delete-on-remove hook (BUR review 2026-10-19).
      should "take a nuked tag off every view and bring its provenance back on revert" do
        @post = create(:post, tag_string: "foo bar")
        FourierTagSource.record_partition!(@post, { auto: %w[foo bar] }, @admin)
        create_bur!("nuke bar", @admin)

        assert_equal("foo", @post.reload.tag_string)
        [nil, create(:user), @admin].each do |viewer|
          assert_not_includes(FourierTagSource.for_viewer(@post, viewer).values.flatten, "bar", viewer&.level_string.inspect)
          assert_not_includes(FourierTagSource.blacklist_tags_for([@post], viewer)[@post], "bar", viewer&.level_string.inspect)
        end

        @post.revert_to!(@post.versions.order(:version).first)
        assert_equal("bar foo", @post.reload.tag_string)
        assert_equal(%w[bar foo], FourierTagSource.for_viewer(@post, nil)[:auto].sort)
      end

      should "remove implications" do
        @ti1 = create(:tag_implication, antecedent_name: "fly", consequent_name: "insect")
        @ti2 = create(:tag_implication, antecedent_name: "insect", consequent_name: "bug")
        @bur = create_bur!("nuke insect", @admin)

        assert_equal("deleted", @ti1.reload.status)
        assert_equal("deleted", @ti2.reload.status)
        assert_equal("approved", @bur.reload.status)
      end

      should "remove pools by id" do
        @pool = create(:pool, id: 123)
        @post = create(:post, tag_string: "bar pool:123")
        @bur = create_bur!("nuke pool:123", @admin)

        assert_equal([], @pool.post_ids)
        assert_equal("approved", @bur.reload.status)
        assert_equal(User.system, @pool.versions.last.updater)
      end

      should "remove pools by name" do
        @pool = create(:pool, name: "asd")
        @post = create(:post, tag_string: "bar pool:asd")
        @bur = create_bur!("nuke pool:asd", @admin)

        assert_equal([], @pool.post_ids)
        assert_equal("approved", @bur.reload.status)
        assert_equal(User.system, @pool.versions.last.updater)
      end

      # Fork: the processor records what the mass update did on the line.
      should "pass the mass update result up" do
        result = { matched: 3, skipped: [] }
        BulkUpdateRequest::Command::MassUpdate.stubs(:mass_update).returns(result)

        assert_same(result, BulkUpdateRequest::Command.parse("nuke bar").process!(approver: @admin, forum_topic: nil))
      end
    end
  end
end
