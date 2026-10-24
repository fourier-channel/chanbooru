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
end
