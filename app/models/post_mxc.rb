# frozen_string_literal: true

# Every address of a post's image (GATE 3 FOR POSTS, fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md): the post's own mxc:// source
# ('post_source', recorded when the post is made, and by migration
# 20261015000001 for the posts made before) and each re-upload of the same
# bytes the tunnel maps to it by md5 ('alias', POST /posts/:id/tag_sources
# with "mxc"). An mxc belongs to ONE post (UNIQUE mxc).
#
# posts.room_ids is derived from these rows and matrix_media, never written
# from anywhere else (.recompute_room_ids!):
#
#   {0}   not a Matrix post: no 'post_source' row and a source that is not an
#         mxc. A booru post whose bytes were later re-uploaded in Matrix keeps
#         {0}: its image is served by the booru door, which follows the post,
#         so the alias adds nothing to who may see it;
#   {..}  a Matrix post: the sorted union of the rooms of its mxcs that
#         fourier-auth has answered for, plus -1 if any of them is a site
#         asset;
#   {}    a Matrix post none of whose mxcs has an answer yet: nobody but the
#         pipeline sees it once the gate is on (fail closed).
class PostMxc < ApplicationRecord
  POST_SOURCE = "post_source"
  ALIAS = "alias"

  belongs_to :post

  # Map `post`'s own mxc:// source to it. False when that mxc already
  # belongs to another post: then this post has no answer to open it and
  # stays closed ({}), and the log says which.
  def self.record_post_source!(post)
    mapped = record!(post, post.source, POST_SOURCE) == post.id
    Rails.logger.warn("gate3: post ##{post.id}'s source #{post.source} already belongs to another post in post_mxcs; post ##{post.id} stays hidden from every viewer until that mapping is corrected (fix the post_mxcs row by hand)") unless mapped
    recompute_room_ids!([post.id])
    mapped
  end

  # Record the tunnel's report that `mxc` is another address of `post`'s
  # image. :accepted (also when already recorded) or :mxc_mapped_elsewhere.
  def self.record_alias!(post, mxc)
    return :mxc_mapped_elsewhere unless record!(post, mxc, ALIAS) == post.id

    recompute_room_ids!([post.id])
    :accepted
  end

  # Map `mxc` to `post` unless it belongs to a post already; the id of the
  # post it belongs to after the write.
  def self.record!(post, mxc, source)
    now = Time.zone.now
    insert_all([{ post_id: post.id, mxc: mxc, source: source, created_at: now, updated_at: now }], unique_by: :mxc)
    where(mxc: mxc).pick(:post_id)
  end
  private_class_method :record!

  # Recompute posts.room_ids for `post_ids` from post_mxcs and matrix_media
  # as they stand, each post locked first, so two writers touching different
  # mxcs of one post cannot each write a set missing the other's change (the
  # second waits, then reads what the first committed). A row whose set is
  # unchanged is not written.
  def self.recompute_room_ids!(post_ids)
    post_ids.uniq.sort.each_slice(500) do |ids|
      transaction do
        posts = Post.where(id: ids).order(:id).lock.pluck(:id, :source)
        maps = where(post_id: ids).pluck(:post_id, :mxc, :source).group_by(&:first)
        media = MatrixMedia.where(mxc: maps.values.flatten(1).map(&:second)).pluck(:mxc, :room_ids, :site_asset).index_by(&:first)
        posts.each do |id, source|
          rooms = room_ids_for(source, maps.fetch(id, []), media)
          Post.where(id: id).where("posts.room_ids IS DISTINCT FROM ?::integer[]", "{#{rooms.join(",")}}").update_all(room_ids: rooms)
        end
      end
    end
  end

  # The room set for a post with `source`, its post_mxcs rows `maps`
  # ([post_id, mxc, source]) and `media` ({ mxc => [mxc, room_ids, site_asset] }).
  def self.room_ids_for(source, maps, media)
    matrix = maps.any? { |_, _, kind| kind == POST_SOURCE } || source.to_s.start_with?("mxc://")
    return [MatrixViewerRooms::NOT_MATRIX] unless matrix

    known = maps.filter_map { |_, mxc, _| media[mxc] }
    rooms = known.flat_map(&:second)
    rooms << MatrixViewerRooms::SITE_ASSET if known.any?(&:third)
    rooms.uniq.sort
  end
end
