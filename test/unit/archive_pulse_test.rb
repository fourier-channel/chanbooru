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

  # A pass of three uploads, three seconds apart, starting `ago` seconds before
  # @now. Not named `pass`: Minitest has an assertion by that name, and a def
  # inside a shoulda context does not reach the test class, so the tests
  # silently called Minitest's and created nothing.
  def upload_pass(ago, tags: "landscape")
    [0, 3, 6].map { |s| create(:post, tag_string: tags, created_at: @now - ago.seconds + s.seconds) }
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

    # Nothing schedules the next upload -- the poster runs a pass, sleeps, and
    # posts whatever the taggers have cleared -- so "when is the next one" can
    # only be read off the rhythm of the last few. Uploads arrive as passes: a
    # handful seconds apart, then a pause. The pace is the usual gap between
    # the STARTS of those passes.
    context "cadence" do
      setup do
        @now = Time.zone.parse("2026-09-25 12:00:00")
        travel_to(@now)
      end

      teardown { travel_back }

      should "read the gap between passes, not between posts" do
        [900, 720, 540, 360, 180, 6].each { |ago| upload_pass(ago) }

        cadence = ArchivePulse.new(viewer: create(:user)).cadence

        assert_equal(180, cadence[:every])
        assert_equal(@now - 6.seconds, cadence[:burst_at])
        assert_equal(@now, cadence[:last_at])
      end

      # One stray upload between passes (a person, or the tunnel) halves one
      # gap; the median does not follow it.
      should "not be thrown by a lone upload between passes" do
        [900, 720, 540, 360, 180, 6].each { |ago| upload_pass(ago) }
        create(:post, tag_string: "landscape", created_at: @now - 450.seconds)

        assert_equal(180, ArchivePulse.new(viewer: create(:user)).cadence[:every])
      end

      should "say nothing with too little recent history to go by" do
        [540, 360, 180].each { |ago| upload_pass(ago) }

        assert_nil(ArchivePulse.new(viewer: create(:user)).cadence)
      end

      should "ignore uploads older than the window" do
        [4.hours, 3.hours + 57.minutes, 3.hours + 54.minutes, 3.hours + 51.minutes, 3.hours + 48.minutes].each { |ago| upload_pass(ago.to_i) }

        assert_nil(ArchivePulse.new(viewer: create(:user)).cadence)
      end

      # The pace of the gated set is as much a statement about its volume as
      # a count would be, so it is read over what this viewer can reach.
      # The component hands the tooltip timestamps, never phrases, and leaves
      # the pace out entirely when there is none -- the script words "too few
      # recent uploads" from the absence.
      should "hand the tooltip timestamps, and no pace when there is none" do
        [540, 360, 180].each { |ago| upload_pass(ago) }
        sparse = ArchivePulseComponent.new(pulse: ArchivePulse.new(viewer: create(:user))).live_data
        assert_equal([:newest_at], sparse.keys)

        Cache.clear
        [900, 720].each { |ago| upload_pass(ago) }
        steady = ArchivePulseComponent.new(pulse: ArchivePulse.new(viewer: create(:user))).live_data
        assert_equal(%i[newest_at last_at burst_at every], steady.keys)
        assert_equal((@now - 180.seconds).iso8601, steady[:burst_at])
        assert_equal(180, steady[:every])
      end

      should "not read the pace of posts the viewer cannot see" do
        gated = Danbooru.config.restricted_tags.first
        skip "no gated tags configured" if gated.blank?

        [900, 720, 540, 360, 180, 6].each { |ago| upload_pass(ago, tags: gated) }

        assert_not_nil(ArchivePulse.new(viewer: create(:user)).cadence)
        assert_nil(ArchivePulse.new(viewer: User.anonymous).cadence)
      end
    end
  end
end
