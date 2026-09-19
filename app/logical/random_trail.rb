# frozen_string_literal: true

# RANDOM MODE HAS A HISTORY. Operator, 2026-09-19:
#
#   "When scrolling on random, the only true random posts should show up in
#   the direction of your scroll. The rest should be kept as walkable
#   history. Currently, swapping to a new page for any reason randomizes both
#   last and next. This is only appropriate for the initial load, which
#   becomes saved state. After that, scrolling beyond anything already
#   recorded as seen will load a new random post in that direction. ... The
#   point of this is to allow a user to travel between tags, and so long as
#   they follow their exact footsteps back through random, they could find
#   any artist they might have wanted to check up on."
#
# So a trail: the ordered list of post ids random has shown for a search, per
# viewer. Standing on a post that is on the trail, its neighbours are the
# trail's; standing at either end, the missing neighbour is ROLLED -- one
# fresh pick from the search, never one already on the trail -- and written
# to that end. Arriving on a post random has not shown (a click in from a
# search, say) appends it: back is where you were, forward is new. Nothing
# on the trail is ever re-rolled until the viewer clears it, which reseeds
# both directions -- "the cycle completes".
#
# WHERE IT LIVES. A signed-in viewer's trails are a jsonb map on their
# ModulationSetting row, one per search, capped (TRAILS) with the least
# recently walked evicted. An anonymous viewer has the session cookie, which
# is a few kilobytes, so they keep ONE trail, shorter (ANON_MAX). Both are
# bounded (MAX): a trail that outgrows the cap drops its far end -- the end
# the viewer is walking away from.
#
# The search key is the base tags with any order: stripped, because the
# random preset's search IS the base search under order:random, and a trail
# should survive the viewer switching modes and back.
class RandomTrail
  MAX = 300
  ANON_MAX = 80
  TRAILS = 6
  SESSION_KEY = :modulation_random_trail

  attr_reader :search, :ids

  def self.key_for(search)
    search.to_s.gsub(/\border:\S+/i, "").squish
  end

  # The trail for `viewer` (and `session`, for an anonymous viewer) on `search`.
  def self.for(viewer, session, search)
    new(viewer, session, key_for(search))
  end

  def initialize(viewer, session, key)
    @viewer = viewer
    @session = session
    @search = key
    @ids = load_ids
    @dirty = false
  end

  def signed_in?
    @viewer.present? && !@viewer.is_anonymous?
  end

  def cap
    signed_in? ? MAX : ANON_MAX
  end

  def size
    @ids.size
  end

  # { prev_id:, next_id: } for standing on `post`, rolling at the frontier.
  # `roll` is a block: excluded ids -> a fresh post id, or nil when the search
  # has nothing left to give.
  def neighbours_for(post, &roll)
    i = @ids.index(post.id)
    if i.nil?
      # A fresh arrival: back is the last post random showed, forward is new.
      @ids.push(post.id)
      @dirty = true
      i = @ids.size - 1
    end
    if i.zero?
      fresh = roll.call(@ids)
      if fresh
        @ids.unshift(fresh)
        @dirty = true
        i += 1
      end
    end
    if i == @ids.size - 1
      fresh = roll.call(@ids)
      if fresh
        @ids.push(fresh)
        @dirty = true
      end
    end
    trim(i)
    { prev_id: (i.positive? ? @ids[i - 1] : nil), next_id: @ids[i + 1] }
  end

  # Forget everything for this search. The next payload reseeds both sides.
  def clear!
    @ids = []
    @dirty = true
    save!
  end

  def save!
    return unless @dirty

    if signed_in?
      row = ModulationSetting.find_or_initialize_by(user_id: @viewer.id)
      trails = (row.random_trails || {}).dup
      if @ids.empty?
        trails.delete(@search)
      else
        trails[@search] = { "ids" => @ids, "t" => Time.now.to_i }
        # Evict the least recently walked when over the cap.
        while trails.size > TRAILS
          oldest = trails.min_by { |_, v| v.is_a?(Hash) ? v["t"].to_i : 0 }&.first
          trails.delete(oldest)
        end
      end
      row.update!(random_trails: trails)
    elsif @session
      @session[SESSION_KEY] = @ids.empty? ? nil : { "q" => @search, "ids" => @ids }
    end
    @dirty = false
  end

  private

  def load_ids
    if signed_in?
      row = ModulationSetting.find_by(user_id: @viewer.id)
      entry = row && row.random_trails.is_a?(Hash) ? row.random_trails[@search] : nil
      Array(entry.is_a?(Hash) ? entry["ids"] : nil).map(&:to_i)
    elsif @session
      entry = @session[SESSION_KEY]
      entry.is_a?(Hash) && entry["q"] == @search ? Array(entry["ids"]).map(&:to_i) : []
    else
      []
    end
  end

  # Keep the trail within the cap by dropping the end the viewer is walking
  # away from: standing near the front, drop the back, and the reverse.
  def trim(i)
    return if @ids.size <= cap

    if i < @ids.size / 2
      @ids = @ids.first(cap)
    else
      @ids = @ids.last(cap)
    end
    @dirty = true
  end
end
