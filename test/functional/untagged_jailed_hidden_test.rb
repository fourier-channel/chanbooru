# frozen_string_literal: true

require "test_helper"

# boo.122 D3 (2026-11-20): a jailed post is hidden from everyone but the
# pipeline, admins included -- but every hidden term asked the TAG
# (TagBanishment.post_tags), and Post#jailed? also reads the log: a post the
# jail deleted (#deletion_is_the_jails?) or reported (#jailing_stands?) is
# jailed with the tag gone. 429 production posts were so -- the
# concurrent-edit race (concurrent_post_edit_test) took troll_jail off them
# -- and each was shown to an admin: its page, its json, status:deleted,
# its card, its children's parent, and the Matrix door's document.
#
# Post.untagged_jailed_ids is those posts by id; each hidden term adds it.
# Deleted-post visibility and the banished-post rule are relaxed under test,
# so both are stubbed to the production shape, and every fixture first
# asserts it is what it stands for: jailed, deleted, without the tag.
class UntaggedJailedHiddenTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"

  context "A jailed post without the jail tag" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!

      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @uploader = create(:contributor_user) # posts several fixtures: no upload limit

      # Jailed by the jail panel's account, as sampling's jailSync jails --
      # the tag, then the deletion -- and the tag then lost, as the race
      # lost it: through an ordinary save, which is what the race was.
      @by_deletion = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@sample) { @by_deletion.update!(tag_string: "landscape #{JAIL}") }
      @by_deletion.reload.delete!("troll jail: shock", user: @sample)
      as(@sample) { @by_deletion.reload.update!(tag_string: "landscape") }
      @by_deletion.reload

      # Deleted by hand, then reported to the booru as a jailing (post_jail).
      @by_report = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @by_report.delete!("duplicate", user: @admin)
      ModAction.log("jailed post ##{@by_report.id}, reason: troll jail: reported", :post_jail, subject: @by_report, user: User.system)
      @by_report.reload

      # Control: an ordinary deletion, which an admin sees.
      @deleted = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @deleted.delete!("duplicate", user: @admin)
      @deleted.reload

      [@by_deletion, @by_report].each do |post|
        assert post.is_deleted? && post.jailed?, "fixture: post ##{post.id} is jailed"
        assert_not post.has_tag?(JAIL), "fixture: post ##{post.id} has lost the tag"
      end
      assert_not @deleted.jailed?, "fixture: the ordinary deletion is not jailed"
      assert_not @deleted.hidden_from?(@admin), "fixture: an admin sees an ordinary deletion"
    end

    should "be the set, which is exactly the jailed posts without the tag" do
      assert_equal [@by_deletion.id, @by_report.id].sort, Post.untagged_jailed_ids.to_a.sort
    end

    should "be hidden from an admin, as its tagged siblings are" do
      [@by_deletion, @by_report].each do |post|
        assert post.hidden_from?(@admin), "post ##{post.id}"
        assert_not Post.without_hidden_posts(@admin).exists?(id: post.id), "post ##{post.id} in without_hidden_posts"

        get_auth post_path(post, format: :json), @admin
        assert_response 404
      end
    end

    should "be hidden from its own uploader" do
      assert @by_deletion.hidden_from?(@uploader)
      assert_not Post.without_hidden_posts(@uploader).exists?(id: @by_deletion.id)
    end

    should "not be listed by an admin's status:deleted search" do
      get_auth posts_path(format: :json), @admin, params: { tags: "status:deleted", limit: 100 }

      assert_response :success
      ids = response.parsed_body.pluck("id")
      assert_includes ids, @deleted.id, "control: the ordinary deletion is listed"
      assert_not_includes ids, @by_deletion.id
      assert_not_includes ids, @by_report.id
    end

    should "not be drawn as a card in a list that shows deleted posts" do
      assert PostPreviewComponent.listed?(@deleted, @admin, show_deleted: true), "control"
      assert_not PostPreviewComponent.listed?(@by_deletion, @admin, show_deleted: true)
    end

    should "not be named to an admin as a child's parent" do
      child = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      child.update_columns(parent_id: @by_deletion.id)

      get_auth posts_path(format: :json), @admin, params: { tags: "id:#{child.id} parent:any" }
      assert_response :success
      assert_empty response.parsed_body

      get_auth posts_path(format: :json), @admin, params: { tags: "id:#{child.id} parent:none" }
      assert_equal [child.id], response.parsed_body.pluck("id")
    end

    should "be listed as jailed in the Matrix door's document" do
      rows = TagQuarantine.document(reader: @sample, after: nil)[:posts].index_by { |row| row[:id] }

      assert_equal true, rows.dig(@by_deletion.id, :jailed)
      assert_equal true, rows.dig(@by_report.id, :jailed)
      assert_nil rows[@deleted.id], "control: an ordinary deletion is not in the document"
    end

    # The pipeline is spared the jail term, not deletion (sample is level 37,
    # deleted posts show from 50 on production). Let it see deletions here,
    # so only the jail term is asked: still hiding it from an admin, sparing
    # the pipeline.
    should "not be hidden from the pipeline by the jail term" do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(@sample.level)

      assert_not @by_deletion.hidden_from?(@sample)
      assert Post.without_hidden_posts(@sample).exists?(id: @by_deletion.id)
      assert @by_deletion.hidden_from?(@admin), "control: the jail term still hides it from an admin"
    end

    should "join the set when the tag comes off, with the set already read" do
      tagged = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@sample) { tagged.update!(tag_string: "landscape #{JAIL}") }
      tagged.reload.delete!("troll jail: shock", user: @sample)
      assert_not_includes Post.untagged_jailed_ids, tagged.id, "fixture: tagged, so not in the set"

      # No mod action: the tag edit alone has to move the set, in this
      # process and in the shared cache.
      as(@sample) { tagged.reload.update!(tag_string: "landscape") }

      assert_includes Post.untagged_jailed_ids, tagged.id
      assert tagged.reload.hidden_from?(@admin)
    end

    should "leave the set and be seen when released" do
      ModAction.log("undeleted post ##{@by_deletion.id}", :post_undelete, subject: @by_deletion, user: @sample)
      @by_deletion.update_columns(is_deleted: false)

      assert_not_includes Post.untagged_jailed_ids, @by_deletion.id
      assert_not @by_deletion.reload.hidden_from?(@admin)
    end
  end
end
