# frozen_string_literal: true

# A record that holds a LIST of post ids (Pool, FavoriteGroup), as it exists
# for one viewer (CREATOR_VISIBILITY section 6, 2026-10-08): its post_ids
# without the posts hidden from them, which is what the API's post_ids and
# post_count, the page, the order form and the post page's navigation show.
# A hidden post in a public pool was its "next" link, its numbering and an
# id in /pools.json.
#
# The STORED list stays whole: an editor who cannot see a post never removes
# it (keep_unseen_post_ids), and a viewer who can still sees it in place.
module PostIdList
  extend ActiveSupport::Concern

  class_methods do
    # Decide a page of these records for `user` in one query, not one a
    # record (HiddenPostIds). Called by every door that lists them.
    #
    # @return [Array] the records, loaded
    def preload_visible_post_ids(records, user = CurrentUser.user)
      records = records.to_a
      hidden = HiddenPostIds.new(user, records.flat_map(&:post_ids))
      records.each { |record| record.hidden_post_ids = hidden }
    end
  end

  attr_writer :hidden_post_ids

  # post_ids without the posts hidden from `user`, in their stored order.
  def visible_post_ids(user = CurrentUser.user)
    @hidden_post_ids = HiddenPostIds.new(user) unless @hidden_post_ids && @hidden_post_ids.user == user
    @hidden_post_ids.visible(post_ids)
  end

  # Called before a save from the edit form or the API, whose list was built
  # from visible_post_ids: the ids `user` cannot see that the new list lacks
  # go back where they were -- each after the id that preceded it in the old
  # list and is still in the new one, or first if none is -- so an edit by
  # someone who cannot see a page never moves it for those who can (review,
  # 2026-10-08: appended at the end, a private page of a comic jumped).
  def keep_unseen_post_ids(user = CurrentUser.user)
    return unless post_ids_changed?

    old = post_ids_was
    dropped = old - post_ids
    unseen = (dropped - Post.visible_ids_among(dropped, user)).to_set
    return if unseen.empty?

    # anchor id => the unseen ids that followed it in the old list; nil for
    # those before any id the new list keeps.
    kept = post_ids.to_set
    after = old.slice_before { |id| kept.include?(id) }
               .group_by { |run| kept.include?(run.first) ? run.first : nil }
               .transform_values { |runs| runs.flatten.select { |id| unseen.include?(id) } }
    self.post_ids = after.fetch(nil, []) + post_ids.flat_map { |id| [id, *after.delete(id)] }
  end

  def serializable_hash(...)
    hash = super
    hash["post_ids"] = visible_post_ids if hash.key?("post_ids")
    hash
  end
end
