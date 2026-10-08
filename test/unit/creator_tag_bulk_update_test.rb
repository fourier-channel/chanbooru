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
end
