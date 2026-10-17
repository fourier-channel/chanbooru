# frozen_string_literal: true

require "test_helper"

# RANDOM MODE'S TRAIL (RandomTrail): what random has shown, walkable back.
#
# Characterised at depth 1 -- the behaviour random has had since 2026-09-19 --
# and then at the flank depth, where a side carries several candidates so a
# blocked one can be stepped over on the page. The rule that must survive the
# depth: only the frontier is rolled, once a payload. Rolling DEPTH fresh posts
# would cost DEPTH md5 seeks on every signed-in post view (the 44 s roll class,
# test/unit/modulation_random_neighbours_test.rb) and fill the trail with
# posts nobody was shown.
class RandomTrailTest < ActiveSupport::TestCase
  Stand = Struct.new(:id)

  # An anonymous viewer's trail, held in a session Hash, starting at `ids`.
  def trail(ids = [])
    session = {}
    session[RandomTrail::SESSION_KEY] = { "q" => "", "ids" => ids } if ids.any?
    RandomTrail.new(nil, session, "")
  end

  # A roll block handing out `fresh` in order (nil once spent), recording what
  # it was told to exclude on each call.
  def roller(*fresh)
    calls = []
    roll = lambda do |taken|
      calls << taken.dup
      fresh.shift
    end
    [calls, roll]
  end

  context "at depth 1" do
    should "append an off-trail arrival: back is where you were, forward is new" do
      t = trail([1, 2])
      calls, roll = roller(50)
      found = t.neighbours_for(Stand.new(9), &roll)

      assert_equal [1, 2, 9, 50], t.ids
      assert_equal({ prev_ids: [2], next_ids: [50], prev_more: true, next_more: true }, found)
      assert_equal [[1, 2, 9]], calls, "rolled once, told the whole trail (the post included)"
    end

    should "roll one fresh post onto the front when standing on the first" do
      t = trail([5, 6, 7])
      calls, roll = roller(4)
      found = t.neighbours_for(Stand.new(5), &roll)

      assert_equal [4, 5, 6, 7], t.ids
      assert_equal [4], found[:prev_ids]
      assert_equal [6], found[:next_ids]
      assert_equal 1, calls.size
    end

    should "roll one fresh post onto the back when standing on the last" do
      t = trail([5, 6, 7])
      calls, roll = roller(8)
      found = t.neighbours_for(Stand.new(7), &roll)

      assert_equal [5, 6, 7, 8], t.ids
      assert_equal [6], found[:prev_ids]
      assert_equal [8], found[:next_ids]
      assert_equal 1, calls.size
    end

    should "give no neighbour on a side the search has nothing left for" do
      t = trail
      _, roll = roller(nil, nil)
      found = t.neighbours_for(Stand.new(3), &roll)

      assert_equal [3], t.ids
      assert_equal({ prev_ids: [], next_ids: [], prev_more: false, next_more: false }, found)
    end

    # The trim used to run after the index was taken: once a full trail
    # dropped its front, prev named the post itself and next nothing.
    should "keep the neighbours right when a full trail drops its far end" do
      t = trail((1..RandomTrail::ANON_MAX).to_a)
      _, roll = roller(1000)
      found = t.neighbours_for(Stand.new(RandomTrail::ANON_MAX), &roll)

      assert_equal RandomTrail::ANON_MAX, t.size
      assert_equal 2, t.ids.first, "the end walked away from is the one dropped"
      assert_equal [RandomTrail::ANON_MAX - 1], found[:prev_ids]
      assert_equal [1000], found[:next_ids]
    end
  end

  context "at the flank depth" do
    should "give known entries either side, nearest first, rolling nothing mid-trail" do
      t = trail((1..20).to_a)
      calls, roll = roller(99)
      found = t.neighbours_for(Stand.new(10), depth: 6, &roll)

      assert_equal [9, 8, 7, 6, 5, 4], found[:prev_ids]
      assert_equal [11, 12, 13, 14, 15, 16], found[:next_ids]
      assert(found[:prev_more])
      assert(found[:next_more])
      assert_empty calls, "a post with DEPTH known entries each side rolls nothing"
      assert_equal (1..20).to_a, t.ids
    end

    # The window reaching the trail's end is not the end of random: a hop to
    # that entry rolls the next fresh one.
    should "say more on a side whose window reaches the trail's end unrolled" do
      t = trail([1, 2, 3, 4, 5])
      calls, roll = roller(77)
      found = t.neighbours_for(Stand.new(3), depth: 6, &roll)

      assert_equal({ prev_ids: [2, 1], next_ids: [4, 5], prev_more: true, next_more: true }, found)
      assert_empty calls
    end

    should "roll at most one fresh post per end, never a duplicate or the post itself" do
      t = trail
      calls, roll = roller(7, 8, 9, 10)
      found = t.neighbours_for(Stand.new(3), depth: 6, &roll)

      assert_equal 2, calls.size, "one roll per end"
      assert_equal [7, 3, 8], t.ids
      assert_equal({ prev_ids: [7], next_ids: [8], prev_more: true, next_more: true }, found)
      all = found[:prev_ids] + found[:next_ids]
      assert_equal all.uniq, all
      assert_not_includes all, 3
    end

    should "say no more on a side only once its roll came back empty" do
      t = trail([1, 2, 3])
      calls, roll = roller(nil)
      found = t.neighbours_for(Stand.new(3), depth: 6, &roll)

      assert_equal({ prev_ids: [2, 1], next_ids: [], prev_more: true, next_more: false }, found)
      assert_equal 1, calls.size

      t = trail([1, 2, 3])
      _, roll = roller(nil)
      found = t.neighbours_for(Stand.new(1), depth: 6, &roll)
      assert_equal({ prev_ids: [], next_ids: [2, 3], prev_more: false, next_more: true }, found)
    end
  end
end
