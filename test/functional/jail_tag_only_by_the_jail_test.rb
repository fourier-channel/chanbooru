# frozen_string_literal: true

require "test_helper"

# R2 (operator 2026-11-20): "Only the jail adds troll_jail. A hand edit, bulk
# update or mass update that adds it is refused with a message, and a live
# post carrying the tag is never treated as jailed."
#
# Until then any approver could type troll_jail onto a post or off it, an
# alias or implication could carry it onto or off every post it touched, and
# a live post carrying the tag was drawn as jailed. The jail is the jail
# panel's account (sample, Post.jail_tagger?) and the booru's own jail acts
# (the banished-tag failsafe, BanishTagJob, the pill's jail-on), which add
# the tag through Post#add_jail_tag!. Removal is refused the same way: only
# the panel's release takes the tag off.
class JailTagOnlyByTheJailTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  JAIL = "troll_jail"

  context "The jail tag" do
    setup do
      @approver = create(:approver_user)
      @moderator = create(:moderator_user)
      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @member = create(:user)
      @post = as(@member) { create(:post, tag_string: "landscape") }
    end

    should "be refused on an approver's hand edit, saying why" do
      put_auth post_path(@post, format: :json), @approver, params: { post: { tag_string: "landscape #{JAIL}" }}

      assert_response 422
      assert_includes response.body, Post::JAIL_TAG_CHANGE_REFUSAL
      assert_not_includes @post.reload.tag_array, JAIL
    end

    should "be refused on an admin's hand edit" do
      put_auth post_path(@post, format: :json), @admin, params: { post: { tag_string: "landscape #{JAIL}" }}

      assert_response 422
      assert_not_includes @post.reload.tag_array, JAIL
    end

    should "be refused on a new post that carries it" do
      post = as(@member) { build(:post, tag_string: "landscape #{JAIL}") }

      as(@member) { assert_not post.valid? }
      assert_includes post.errors.full_messages, Post::JAIL_TAG_CHANGE_REFUSAL
    end

    should "be refused when a tag that implies it is added" do
      # An implication adds only a tag that exists (TagImplication.tags_implied_by),
      # as troll_jail does in production.
      create(:tag, name: JAIL)
      TagImplication.new(antecedent_name: "jail_bait_r2", consequent_name: JAIL, creator: @admin, status: "active").save!(validate: false)

      put_auth post_path(@post, format: :json), @approver, params: { post: { tag_string: "landscape jail_bait_r2" }}

      assert_response 422
      assert_not_includes @post.reload.tag_array, JAIL
    end

    should "not be taken off a live post that carries it by an admin's edit" do
      @post.update_columns(tag_string: "landscape #{JAIL}")

      put_auth post_path(@post, format: :json), @admin, params: { post: { tag_string: "landscape" }}

      assert_response 422
      assert_includes response.body, Post::JAIL_TAG_CHANGE_REFUSAL
      assert_includes @post.reload.tag_array, JAIL
    end

    # A revert, an undo, copy_notes and a duplicate merge save a record loaded
    # before the jail tagged the post. Judged against that copy, the save
    # changed nothing about the jail tag and took it off the row.
    should "not be taken off by a save of a copy loaded before the jail tagged the post" do
      stale = Post.find(@post.id)
      @post.update_columns(tag_string: "landscape #{JAIL}")

      saved = as(@admin) { stale.update(tag_string: "landscape sky") }

      assert_not saved, "the stale save was refused"
      assert_includes stale.errors.full_messages, Post::JAIL_TAG_CHANGE_REFUSAL
      assert_includes @post.reload.tag_array, JAIL
    end

    should "leave an edit of other tags alone on a post that carries it" do
      @post.update_columns(tag_string: "landscape #{JAIL}")

      put_auth post_path(@post, format: :json), @admin, params: { post: { tag_string: "landscape #{JAIL} sky" }}

      assert_response :success
      assert_equal ["landscape", "sky", JAIL].sort, @post.reload.tag_array.sort
    end

    # Controls: the jail itself.
    should "be added and taken off by the jail panel's account" do
      put_auth post_path(@post, format: :json), @sample, params: { post: { tag_string: "landscape #{JAIL}" }}
      assert_response :success
      assert_includes @post.reload.tag_array, JAIL

      put_auth post_path(@post, format: :json), @sample, params: { post: { tag_string: "landscape" }}
      assert_response :success
      assert_not_includes @post.reload.tag_array, JAIL
    end

    should "be added by the banished-tag failsafe" do
      banish_tags!("gore")
      post = as(@member) { create(:post, tag_string: "landscape gore") }.reload

      assert post.is_deleted?
      assert_includes post.tag_array, JAIL
      assert post.jailed?
    end

    should "be added by the pill's jail-on, as a moderator who could not type it" do
      login_as(@moderator)
      patch modulation_moderation_path(@post), params: { jail: true }, as: :json

      assert_response :success
      assert_equal true, response.parsed_body["jailed"]
      assert_includes @post.reload.tag_array, JAIL
      assert @post.is_deleted?
    end

    # The jail acting is not a booru-side jailing (boo.122, 2026-11-20): the
    # panel's account tagging a post someone else deleted wrote a post_jail
    # row as the system user, and the jail feed sent the panel its own act
    # back -- a rejail, or a jail row "by sample".
    should "not report the jail panel's account tagging a post a moderator deleted" do
      as(@moderator) { @post.delete!("spam", user: @moderator) }

      assert_no_difference(-> { ModAction.where(subject: @post, category: "post_jail").count }) do
        put_auth post_path(@post, format: :json), @sample, params: { post: { tag_string: "landscape #{JAIL}" }}
      end
      assert_response :success
      assert @post.reload.jailed?
    end

    should "not report the system user re-tagging a deleted post through Post#add_jail_tag!" do
      as(@moderator) { @post.delete!("spam", user: @moderator) }

      assert_no_difference(-> { ModAction.where(subject: @post, category: "post_jail").count }) do
        CurrentUser.scoped(User.system) { @post.reload.add_jail_tag! }
      end
      assert_includes @post.reload.tag_array, JAIL
    end

    should "still report a moderator deleting a live post that carries it" do
      put_auth post_path(@post, format: :json), @sample, params: { post: { tag_string: "landscape #{JAIL}" }}
      assert_response :success

      assert_difference(-> { ModAction.where(subject: @post, category: "post_jail").count }, 1) do
        as(@moderator) { @post.reload.delete!("spam", user: @moderator) }
      end
    end

    should "report the pill's jail-on once" do
      login_as(@moderator)
      patch modulation_moderation_path(@post), params: { jail: true }, as: :json

      assert_response :success
      assert_equal 1, ModAction.where(subject: @post, category: "post_jail").count
    end

    should "report the banished-tag failsafe's jailing once" do
      banish_tags!("gore")
      post = as(@member) { create(:post, tag_string: "landscape gore") }.reload

      assert post.jailed?
      assert_equal 1, ModAction.where(subject: post, category: "post_jail").count
    end

    should "make Post#add_jail_tag! raise, naming the remedy, when an alias takes it away" do
      TagAlias.new(antecedent_name: JAIL, consequent_name: "jail_elsewhere_r2", creator: @admin, status: "active").save!(validate: false)

      error = assert_raises(ActiveRecord::RecordNotSaved) do
        CurrentUser.scoped(User.system) { @post.add_jail_tag! }
      end
      assert_match(/alias, implication, rename or deprecation of #{JAIL}/, error.message)
    end
  end

  context "A live post carrying the jail tag" do
    setup do
      @moderator = create(:moderator_user)
      @admin = create(:admin_user)
      @post = create(:post, tag_string: "landscape")
      @post.update_columns(tag_string: "landscape #{JAIL}")
      @post.reload
    end

    should "not be jailed" do
      assert_not @post.jailed?
    end

    should "not be drawn as jailed on its page" do
      get_auth post_path(@post), @admin, params: { preset: "modulation" }

      assert_response :success
      payload = modulation_payload(response.body)
      assert_not_includes payload["notices"].map { |n| n["kind"] }, "jailed"
      assert_equal false, payload.dig("moderation", "jailed")
    end

    should "answer the pill's jail-off with what to do, not with the jailed door" do
      login_as(@moderator)
      patch modulation_moderation_path(@post), params: { jail: false }, as: :json

      assert_response :unprocessable_entity
      assert_equal Post::JAIL_TAG_ON_LIVE_POST, response.parsed_body["refused"]
      assert_equal false, response.parsed_body["jailed"]
      assert_includes @post.reload.tag_array, JAIL
    end
  end

  context "Filing" do
    setup do
      @admin = create(:admin_user)
    end

    should "refuse an alias or implication onto or from the jail tag" do
      [
        build(:tag_alias, antecedent_name: "jail_bait_r2", consequent_name: JAIL, creator: @admin),
        build(:tag_alias, antecedent_name: JAIL, consequent_name: "jail_elsewhere_r2", creator: @admin),
        build(:tag_implication, antecedent_name: "jail_bait_r2", consequent_name: JAIL, creator: @admin),
      ].each do |relationship|
        assert_not relationship.valid?, "#{relationship.antecedent_name} -> #{relationship.consequent_name}"
        assert relationship.errors.full_messages.any? { |m| m.include?("only the jail adds or removes it") }
      end
    end

    should "let a retired alias of the jail tag be saved" do
      relationship = build(:tag_alias, antecedent_name: JAIL, consequent_name: "jail_elsewhere_r2", creator: @admin, status: "retired")

      assert relationship.valid?, relationship.errors.full_messages.join("; ")
    end

    should "refuse a bulk update request whose line names the jail tag" do
      ["mass update landscape -> #{JAIL}", "mass update #{JAIL} -> -#{JAIL}", "create alias jail_bait_r2 -> #{JAIL}"].each do |script|
        bur = as(@admin) { build(:bulk_update_request, user: @admin, script: script) }

        as(@admin) { assert_not bur.valid?, script }
        assert bur.errors.full_messages.any? { |m| m.include?("names #{JAIL}") }, "#{script}: #{bur.errors.full_messages}"
      end
    end

    # The search only picks the posts: naming the jail tag there adds and
    # removes nothing (review 2026-11-20: it was refused as well).
    should "let a mass update name the jail tag in its search, and refuse one whose edit names it" do
      ["mass update landscape -#{JAIL} -> sky", "mass update #{JAIL} -> sky", "update #{JAIL} landscape -> -sky"].each do |script|
        ok = as(@admin) { build(:bulk_update_request, user: @admin, script: script) }
        as(@admin) { ok.valid? }
        assert ok.errors.full_messages.none? { |m| m.include?("names #{JAIL}") }, "#{script}: #{ok.errors.full_messages}"
      end

      ["mass update landscape -#{JAIL} -> -#{JAIL}", "mass update landscape -#{JAIL} -> #{JAIL}", "mass update #{JAIL} -> -#{JAIL}", "mass update sky -> landscape #{JAIL}"].each do |script|
        bur = as(@admin) { build(:bulk_update_request, user: @admin, script: script) }
        as(@admin) { assert_not bur.valid?, script }
        assert bur.errors.full_messages.any? { |m| m.include?("names #{JAIL}") }, "#{script}: #{bur.errors.full_messages}"
      end
    end

    # Taking a relationship off the jail tag adds nothing to any post, and
    # an old one must stay removable (review 2026-11-20).
    should "let a bulk update request remove an alias or implication of the jail tag" do
      ["remove alias jail_bait_r2 -> #{JAIL}", "remove implication jail_bait_r2 -> #{JAIL}", "remove alias #{JAIL} -> jail_elsewhere_r2"].each do |script|
        bur = as(@admin) { build(:bulk_update_request, user: @admin, script: script) }
        as(@admin) { bur.valid? }
        assert bur.errors.full_messages.none? { |m| m.include?("names #{JAIL}") }, "#{script}: #{bur.errors.full_messages}"
      end
    end

    should "refuse deprecating the jail tag" do
      tag = Tag.find_or_create_by_name(JAIL)

      as(@admin) { assert_not tag.update(updater: @admin, is_deprecated: true) }
      assert_not tag.reload.is_deprecated?
    end
  end

  private

  def modulation_payload(body)
    JSON.parse(body[/data-payload="([^"]*)"/, 1].then { |raw| CGI.unescapeHTML(raw) })
  end
end
