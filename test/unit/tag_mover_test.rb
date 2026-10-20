require "test_helper"

# Fork: what a tag move does to the provenance sidecar's readers.
class TagMoverTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin_user)
    @creator = create(:user)
  end

  # Operator ruling 2026-10-19: a tag on a post's public list shows to
  # everyone, even when the creator's private prompt row names it. A move
  # carries the antecedent's private row onto the consequent
  # (FourierTagSource.move_tag!), so a consequent a person had already put
  # on the public list ends up with a private row behind it -- and must stay
  # what it was to everyone else: a public tag.
  should "leave a hand-added consequent visible to everyone when the antecedent was a creator's private tag" do
    post = as(@creator) { create(:post, uploader: @creator, tag_string: "landscape cons_term") }
    FourierTagSource.record_partition!(post, { creator: ["ante_term"], auto: ["landscape"] }, @admin)
    TagMover.new("ante_term", "cons_term", user: User.system).move!

    assert(FourierTagSource.exists?(post_id: post.id, tag: "cons_term", public: false), "fixture: the move carried the private row")
    assert_equal(%w[cons_term landscape], post.reload.tag_array)
    [nil, create(:user), @admin].each do |viewer|
      label = viewer&.level_string.inspect
      assert_includes(FourierTagSource.for_viewer(post, viewer)[:unsourced], "cons_term", label)
      assert_includes(FourierTagSource.blacklist_tags_for([post], viewer)[post], "cons_term", label)
    end
    assert_equal(["cons_term"], FourierTagSource.for_viewer(post, @creator)[:creator])
  end
end
