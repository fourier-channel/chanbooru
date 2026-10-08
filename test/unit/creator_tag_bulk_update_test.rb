# frozen_string_literal: true

require "test_helper"

# Bulk update requests that move a creator tag (a tag a listed creator prefix
# locks) are approved by an admin alone (CREATOR_VISIBILITY section 3: control
# by tag is safe only while the prefix lock holds).
#
# An approved alias, rename or implication retags every post as the system
# user, which the prefix lock lets through. Upstream lets a BUILDER approve an
# alias between small artist tags and a MODERATOR an implication between small
# character tags -- and creator tags are small artist tags. So a builder could
# alias 4chan_maple -> 41chan_<self> and take control of maple's posts
# (CreatorControl gives a master-prefix tag's posts to the account it names),
# with no admin anywhere.
class CreatorTagBulkUpdateTest < ActiveSupport::TestCase
  def approvable_by?(user, script)
    BulkUpdateRequestPolicy.new(user, BulkUpdateRequest.new(script: script, user: user)).approve?
  end

  setup do
    @builder = create(:builder_user)
    @moderator = create(:moderator_user)
    @admin = create(:admin_user)
    %w[4chan_maple 41chan_bee small_painter other_painter].each do |name|
      create(:tag, name: name, category: Tag.categories.artist, post_count: 10)
    end
    %w[aichan_maple aichan_bee small_hero other_hero].each do |name|
      create(:tag, name: name, category: Tag.categories.character, post_count: 10)
    end
  end

  should "leave a builder's alias and rename between small artist tags as upstream has it" do
    assert approvable_by?(@builder, "alias small_painter -> other_painter")
    assert approvable_by?(@builder, "rename small_painter -> other_painter")
    assert approvable_by?(@moderator, "imply small_hero -> other_hero")
  end

  should "refuse a builder an alias or rename from or to a creator tag" do
    ["alias 4chan_maple -> 41chan_bee", "alias small_painter -> 4chan_maple", "alias 4chan_maple -> other_painter",
     "rename 4chan_maple -> 41chan_bee", "rename small_painter -> 41chan_bee"].each do |script|
      assert_not approvable_by?(@builder, script), script
      assert_not approvable_by?(@moderator, script), script
      assert approvable_by?(@admin, script), script
    end
  end

  should "refuse a moderator an implication from or to a creator tag" do
    ["imply aichan_maple -> aichan_bee", "imply small_hero -> aichan_bee", "imply aichan_maple -> other_hero"].each do |script|
      assert_not approvable_by?(@moderator, script), script
      assert approvable_by?(@admin, script), script
    end
  end

  # Decided 2026-10-08 with creator visibility (stage 3): a bulk retag is not
  # a viewer, so it reaches every post its query matches (Post.bulk_tag_match)
  # -- a post its creator made private, a post under a hidden prefix, a gated
  # one, a deleted one. It used to search as the signed-out visitor (a mass
  # update) or as the moderator-level system user (an implication), so every
  # viewer rule this fork added made it skip posts silently.
  context "a bulk retag" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      CreatorPrefixes.reset!
      CurrentUser.user = @admin
      tunnel = create(:builder_user, name: "tunnel")
      maple = create(:user)
      gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-bulk", user: maple)
      as(tunnel) do
        @private = create(:post, uploader: tunnel, tag_string: "sword")
        @prefixed = create(:post, uploader: tunnel, tag_string: "sword aichan_bee")
        @gated = create(:post, uploader: tunnel, tag_string: "sword child")
        @deleted = create(:post, uploader: tunnel, tag_string: "sword")
        @plain = create(:post, uploader: tunnel, tag_string: "sword")
      end
      FourierPostCreator.create!(post: @private, mxid: gallery.matrix_id, recorded_by: tunnel.id)
      CreatorPostAudience.set!(@private, gallery: gallery, audience: "private", by: maple)
      @deleted.delete!("ordinary deletion", user: @admin)
      @posts = [@private, @prefixed, @gated, @deleted, @plain]
      CreatorVisibility.forget!

      assert @private.hidden_by_creator?(User.system), "fixture: hidden from the system user as a viewer"
      assert @private.hidden_by_creator?(User.anonymous), "fixture: hidden from a signed-out viewer"
    end

    teardown do
      CurrentUser.user = nil
      CreatorPrefixes.reset!
    end

    should "reach every matching post in a mass update" do
      create_bur!("mass update sword -> blade", @admin)

      @posts.each { |post| assert_includes post.reload.tag_array, "blade", "post ##{post.id} (#{post.tag_string})" }
    end

    should "reach every matching post in an implication" do
      TagImplication.approve!(antecedent_name: "sword", consequent_name: "weapon", approver: @admin)

      @posts.each { |post| assert_includes post.reload.tag_array, "weapon", "post ##{post.id} (#{post.tag_string})" }
    end
  end
end
