# frozen_string_literal: true

require "test_helper"

# R3 (operator 2026-11-20): "Tag names carried only by jailed posts are
# hidden like creator-hidden ones." A jailed post is withheld from everyone
# but the pipeline, admins included, but its tag names were not: a name the
# jailed posts alone carried was listed by the tag index and answered by a
# tag's own page, which told whoever asked that a post they cannot see
# exists, and what it is of.
#
# CreatorVisibility.name_hiding_ids now adds Post.withheld_by_jail_ids for every
# viewer the jail withholds from. Deleted-post visibility and the
# banished-post rule are relaxed under test, so both are stubbed to the
# production shape.
class JailedTagNamesHiddenTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  JAIL = "troll_jail"

  context "A tag name carried only by jailed posts" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!

      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @uploader = create(:contributor_user) # posts several fixtures: no upload limit

      # Jailed with the tag on, as the jail panel jails.
      @tagged = as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_shared r3_on_tagged") }
      as(@sample) { @tagged.update!(tag_string: "r3_shared r3_on_tagged #{JAIL}") }
      @tagged.reload.delete!("troll jail: shock", user: @sample)

      # Jailed, and the tag since lost (boo.122 D3).
      @untagged = as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_on_untagged") }
      as(@sample) { @untagged.update!(tag_string: "r3_on_untagged #{JAIL}") }
      @untagged.reload.delete!("troll jail: shock", user: @sample)
      as(@sample) { @untagged.reload.update!(tag_string: "r3_on_untagged") }

      # Withheld without a jailing: a live post carrying the jail tag, which
      # R2 says is not jailed but which the banished-post rule withholds all
      # the same, and a post carrying a banished tag. A name only they carry
      # names a post nobody but the pipeline is shown.
      @live_tagged = as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_on_live") }
      @live_tagged.update_columns(tag_string: "r3_on_live #{JAIL}") # rubocop:disable Rails/SkipsModelValidations -- how a live post comes to carry it is jail_tag_only_by_the_jail_test's
      @banished = as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_on_banished r3_banned") }
      banish_tags!("r3_banned")

      # Controls: a name also on a live post, and a name only on an
      # ordinary deletion, which an admin sees.
      as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_shared") }
      deleted = as(@uploader) { create(:post, uploader: @uploader, tag_string: "r3_on_deleted") }
      deleted.delete!("duplicate", user: @admin)

      [@tagged, @untagged].each do |post|
        assert post.reload.jailed?, "fixture: post ##{post.id} is jailed"
      end
      assert_not @untagged.has_tag?(JAIL), "fixture: the untagged one lost the tag"
    end

    # A source's tags are translated to the booru's own and offered on the
    # upload form; a name only jailed posts carry was offered all the same
    # (review 2026-11-20).
    should "not be offered as a source's translated tag" do
      extractor = Source::Extractor.find("https://example.com/r3-translated.jpg")
      extractor.stubs(:normalized_tags).returns(%w[r3_on_tagged r3_on_untagged r3_shared])

      offered = CurrentUser.scoped(@admin) { extractor.translated_tags.map(&:name) }
      assert_equal %w[r3_shared], offered.sort
    end

    should "be hidden from an admin, on the tag's own page and in the index" do
      %w[r3_on_tagged r3_on_untagged].each do |name|
        assert Tag.find_by_name(name).hidden_from?(@admin), name
      end

      get_auth tags_path(format: :json), @admin, params: { search: { name_matches: "r3_*" }, limit: 100 }
      assert_response :success
      assert_equal %w[r3_on_deleted r3_shared], response.parsed_body.pluck("name").sort
    end

    should "be hidden when the only post carrying it is a live one with the jail tag, or one with a banished tag" do
      assert_not @live_tagged.reload.jailed?, "fixture: R2, a live post with the tag is not jailed"
      assert @live_tagged.hidden_from?(@admin), "fixture: but withheld"
      assert @banished.reload.hidden_from?(@admin), "fixture: the banished-tag post is withheld"

      %w[r3_on_live r3_on_banished].each do |name|
        assert Tag.find_by_name(name).hidden_from?(@admin), name
        assert_not Tag.find_by_name(name).hidden_from?(@sample), "#{name}: shown to the pipeline"
      end
    end

    # The relation list on a visible tag's wiki page, post search and artist
    # page named its aliases and implications whatever posts carried them
    # (review 2026-11-20).
    should "not be named in a visible tag's alias and implication list" do
      create(:tag_implication, antecedent_name: "r3_shared", consequent_name: "r3_on_tagged", status: "active")
      create(:tag_implication, antecedent_name: "r3_shared", consequent_name: "r3_on_deleted", status: "active")
      create(:wiki_page, title: "r3_shared")

      get_auth wiki_page_path("r3_shared"), @admin

      assert_response :success
      assert_includes response.body, "r3_on_deleted", "control: a name an admin sees is listed"
      assert_not_includes response.body, "r3_on_tagged"
    end

    should "be hidden from a signed-out visitor" do
      get tags_path(format: :json), params: { search: { name_matches: "r3_on_*" }, limit: 100 }
      assert_response :success
      assert_not_includes response.parsed_body.pluck("name"), "r3_on_tagged"
      assert_not_includes response.parsed_body.pluck("name"), "r3_on_untagged"
    end

    should "be shown to the pipeline" do
      assert_not Tag.find_by_name("r3_on_tagged").hidden_from?(@sample)
      assert_not Tag.find_by_name("r3_on_untagged").hidden_from?(@sample)
    end

    should "be shown once the post is released" do
      ModAction.log("undeleted post ##{@untagged.id}", :post_undelete, subject: @untagged, user: @sample)
      @untagged.update_columns(is_deleted: false) # rubocop:disable Rails/SkipsModelValidations -- the release, past what this test is about

      assert_not Tag.find_by_name("r3_on_untagged").hidden_from?(@admin)
    end
  end
end
