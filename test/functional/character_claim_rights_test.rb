# frozen_string_literal: true

require "test_helper"

# A claimed original character's category is fixed at character: only an
# admin re-files it (OC ownership, ruled 2026-10-11). Upstream lets any member
# re-file a tag under 50 posts and a builder one under 1,000; on a claimed tag
# neither applies. A post edit that asks anyway is told why its ask was not
# carried out, instead of upstream's silent skip.
class CharacterClaimRightsTest < ActionDispatch::IntegrationTest
  setup do
    CreatorPrefixes.reset!
    @saber = create(:user)
    @builder = create(:builder_user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net", user: @saber)
    CharacterClaim.prepare(@gallery, @saber, "maple").first.file!
    @tag = Tag.find_by_name("maple_(saber)")
  end

  context "the tag's category" do
    should "not be changeable by a builder at 0 posts, nor by its owner, and be by an admin" do
      assert_not(TagPolicy.new(@builder, @tag).can_change_category?)
      assert_not(TagPolicy.new(@saber, @tag).can_change_category?)
      assert(TagPolicy.new(@admin, @tag).can_change_category?)
    end

    should "be left alone on tags#update by a builder, and changed by an admin" do
      put_auth tag_path(@tag), @builder, params: { tag: { category: Tag.categories.general }}
      assert(@tag.reload.character?)

      put_auth tag_path(@tag), @admin, params: { tag: { category: Tag.categories.general }}
      assert(@tag.reload.general?)
    end

    should "stay character on a post edit's general: metatag, with a warning naming its creator" do
      post = as(@builder) { create(:post, tag_string: "maple_(saber)") }
      put_auth post_path(post), @builder, params: { post: { tag_string: "#{post.tag_string} general:maple_(saber)", old_tag_string: post.tag_string }}

      assert(@tag.reload.character?)
      assert_match(/maple_\(saber\).*is @saber's original character: its category stays character\. Ask an admin\./, flash[:notice])
    end

    # Upstream re-files an EMPTY tag as an artist when an artist entry is
    # made for it (Artist#update_tag_category), with no policy asked: on a
    # claimed character that is the same re-file by another door.
    should "not be re-filed as an artist by an artist entry made for it" do
      post_auth artists_path, @builder, params: { artist: { name: "maple_(saber)" }}

      assert(@tag.reload.character?)
      assert_nil(Artist.find_by(name: "maple_(saber)"))
    end

    should "leave an unclaimed tag's category to upstream's rule" do
      other = create(:tag, name: "pine_(saber)", category: Tag.categories.character)

      assert(TagPolicy.new(@builder, other).can_change_category?)
    end
  end
end
