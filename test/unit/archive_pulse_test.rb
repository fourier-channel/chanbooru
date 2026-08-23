# frozen_string_literal: true

require "test_helper"

# The pulse is what a locked-out visitor is given INSTEAD of the pictures, so
# the two things that matter about it are that it says something (a strip
# reading zero argues against the site it is advertising) and that it does not
# say too much (a count taken over posts the viewer may not see reports the size
# of the gated set to exactly the people it is hidden from).
class ArchivePulseTest < ActiveSupport::TestCase
  def setup
    super
    Cache.clear
  end

  context "ArchivePulse" do
    should "count the archive for a member" do
      create(:post, tag_string: "landscape")
      create(:post, tag_string: "portrait")

      pulse = ArchivePulse.new(viewer: create(:user))

      assert_equal(2, pulse.posts)
      assert(pulse.any?)
      assert_not_nil(pulse.newest_at)
    end

    should "not report gated posts to an anonymous visitor" do
      gated = Danbooru.config.restricted_tags.first
      skip "no gated tags configured" if gated.blank?

      create(:post, tag_string: "landscape")
      create(:post, tag_string: gated)

      assert_equal(2, ArchivePulse.new(viewer: create(:user)).posts)
      assert_equal(1, ArchivePulse.new(viewer: User.anonymous).posts)
    end

    should "not report gated tags to an anonymous visitor" do
      gated = Danbooru.config.restricted_tags.first
      skip "no gated tags configured" if gated.blank?

      create(:post, tag_string: "landscape")
      create(:post, tag_string: gated)

      assert_includes(Tag.visible_to(create(:user)).where(post_count: 1..).pluck(:name), gated)
      assert_not_includes(Tag.visible_to(User.anonymous).where(post_count: 1..).pluck(:name), gated)
    end

    should "say nothing rather than zero when the archive is empty" do
      assert_not(ArchivePulse.new(viewer: User.anonymous).any?)
      assert_not(ArchivePulseComponent.new(pulse: ArchivePulse.new(viewer: User.anonymous)).render?)
    end

    # The landing component passes whatever viewer it was built with, and that
    # may be nil. Falling towards anonymous is the same rule the gating uses.
    should "treat a nil viewer as anonymous" do
      assert_equal(User.anonymous.level, ArchivePulse.new(viewer: nil).viewer.level)
    end
  end
end
