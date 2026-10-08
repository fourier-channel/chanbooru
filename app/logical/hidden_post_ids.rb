# frozen_string_literal: true

# WHICH OF THESE POST IDS ARE HIDDEN FROM ONE VIEWER (Post.hidden_from:
# deleted or jailed past what they may see, gated from a signed-out visitor,
# under a hidden creator prefix, hidden by its creator) -- for the records
# that hold LISTS of post ids (pools, favorite groups, pool versions), whose
# ids the row rule ApplicationRecord.without_hidden_posts cannot reach.
#
# One per page, shared by every row on it (review, 2026-10-08): asking per
# row was one query a row -- a /pools.json?limit=1000 was a thousand queries,
# each carrying the viewer's whole hidden-id literal. An id is asked about
# once; ids a row brings that the page did not (a pool version's other
# version) are asked about together, when first needed.
class HiddenPostIds
  attr_reader :user

  def initialize(user, ids = [])
    @user = user
    @hidden = {}
    learn(ids)
  end

  # `ids` in their own order, without the hidden ones.
  def visible(ids)
    learn(ids)
    ids.reject { |id| @hidden[id] }
  end

  private

  def learn(ids)
    fresh = ids.uniq.reject { |id| @hidden.key?(id) }
    return if fresh.empty?

    gone = Post.hidden_ids_among(fresh, user)
    @hidden.merge!(fresh.index_with { |id| gone.include?(id) })
  end
end
