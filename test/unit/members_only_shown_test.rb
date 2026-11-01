# frozen_string_literal: true

require "test_helper"

# The record of what was shown to signed-out viewers (MembersOnly): each
# hour's bucket keeps the most recently SHOWN ids up to its cap, so a post
# shown again is as new as the last one shown and is not the first dropped.
class MembersOnlyShownTest < ActiveSupport::TestCase
  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  should "count an id shown again as shown now, when the cap drops the oldest" do
    # One clock throughout: an hour turning between calls would split the buckets.
    now = Time.utc(2026, 10, 24, 12, 30)
    stub_const(MembersOnly, :RECENT_SHOWN_CAP, 3) do
      MembersOnly.remember_shown_to_anonymous([1, 2, 3], safe_mode: false, now: now)
      MembersOnly.remember_shown_to_anonymous([1], safe_mode: false, now: now)
      MembersOnly.remember_shown_to_anonymous([4], safe_mode: false, now: now)
    end

    assert_equal([3, 1, 4].to_set, MembersOnly.anonymous_recent_shown_ids(false, now: now))
  end

  # The posts placed on a public creator's page someone opened (operator,
  # 2026-11-01): kept as the shown record is kept, this hour's and the last,
  # capped the same way; and only the posts Gate 3 could hide, so what every
  # search inlines stays as short as the Matrix posts placed.
  context "the placed record" do
    setup do
      @matrix = create_list(:post, 4).each { |post| post.update_columns(room_ids: [7]) } # rubocop:disable Rails/SkipsModelValidations
      @redacted = create(:post).tap { |post| post.update_columns(room_ids: []) } # rubocop:disable Rails/SkipsModelValidations
      @plain = create(:post)
      @now = Time.utc(2026, 11, 1, 12, 30)
    end

    should "keep the Matrix posts placed, closed or redacted ones included, and no other" do
      MembersOnly.remember_placed([@matrix.first.id, @redacted.id, @plain.id, 0], now: @now)
      assert_equal([@matrix.first.id, @redacted.id].to_set, MembersOnly.placed_ids(now: @now))
    end

    should "count an id placed again as placed now, when the cap drops the oldest" do
      a, b, c, d = @matrix.map(&:id)
      stub_const(MembersOnly, :PLACED_CAP, 3) do
        MembersOnly.remember_placed([a, b, c], now: @now)
        MembersOnly.remember_placed([a], now: @now)
        MembersOnly.remember_placed([d], now: @now)
      end
      assert_equal([c, a, d].to_set, MembersOnly.placed_ids(now: @now))
    end

    should "be read for this hour and the last, and no longer" do
      MembersOnly.remember_placed([@matrix.first.id], now: @now)
      assert_equal([@matrix.first.id].to_set, MembersOnly.placed_ids(now: @now + 1.hour))
      assert_empty(MembersOnly.placed_ids(now: @now + 2.hours))
    end
  end
end
