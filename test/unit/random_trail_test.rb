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

  # The ids a signed-in viewer's trail on search "q" holds in the database.
  def stored_ids(user)
    ModulationSetting.find_by!(user_id: user.id).random_trails.dig("q", "ids")
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

  # TWO REQUESTS WRITE ONE TRAIL AT ONCE. The post view fetches the post ahead
  # and the post behind together; standing at both ends of the trail, each
  # rolled its own end and saved the whole trail it had loaded, so the second
  # save erased the first one's roll. The post the page had been told was
  # next was then not on the trail at all: its own payload deferred random
  # (the press waited), and walking back no longer retraced the steps
  # (bin/postview-shift random, 2026-10-18). A save lays its own pushes onto
  # the trail as it stands now, under the row's lock.
  context "two requests writing one signed-in trail at once" do
    setup do
      @user = create(:user)
      ModulationSetting.create!(user: @user, random_trails: { "q" => { "ids" => [1, 2, 3], "t" => 1 }})
    end

    should "keep both ends' rolls" do
      front = RandomTrail.new(@user, nil, "q")
      back = RandomTrail.new(@user, nil, "q")
      front.neighbours_for(Stand.new(1), depth: 6) { 50 }
      back.neighbours_for(Stand.new(3), depth: 6) { 60 }
      front.save!
      back.save!

      assert_equal [50, 1, 2, 3, 60], stored_ids(@user)
    end

    should "keep an arrival pushed by one and a roll by the other" do
      arrival = RandomTrail.new(@user, nil, "q")
      roll = RandomTrail.new(@user, nil, "q")
      arrival.neighbours_for(Stand.new(9), depth: 6) { nil }
      roll.neighbours_for(Stand.new(1), depth: 6) { 50 }
      roll.save!
      arrival.save!

      assert_equal [50, 1, 2, 3, 9], stored_ids(@user)
    end

    should "still forget everything on a clear" do
      t = RandomTrail.new(@user, nil, "q")
      t.neighbours_for(Stand.new(3), depth: 6) { 60 }
      t.clear!
      assert_nil stored_ids(@user)
    end
  end

  # A PREFETCH IS NOT A VISIT. The post view fetches neighbours' payloads ahead
  # of the viewer, and every one of those builds pushed its post onto random's
  # trail -- the trail filled with posts the viewer never stood on, and walking
  # back through random retraced steps nobody took. So a prefetch asks holds?
  # first: a post the trail already holds is answered by neighbours_for, which
  # only ever rolls the frontier for it (the next random post in that
  # direction, which the viewer is walking toward); a post it does not hold is
  # never pushed (ModulationPostComponent#random_neighbours).
  context "holds?" do
    should "hold every post on the trail, its ends included" do
      t = trail([1, 2, 3])
      assert t.holds?(Stand.new(1))
      assert t.holds?(Stand.new(2))
      assert t.holds?(Stand.new(3))
    end

    should "not hold a post off the trail, nor anything on an empty one" do
      assert_not trail([1, 2, 3]).holds?(Stand.new(9))
      assert_not trail.holds?(Stand.new(1))
    end

    should "write nothing" do
      t = trail([1, 2, 3])
      t.holds?(Stand.new(9))
      assert_equal [1, 2, 3], t.ids
      t.save!
      assert_equal [1, 2, 3], t.instance_variable_get(:@session)[RandomTrail::SESSION_KEY]["ids"]
    end
  end
end
