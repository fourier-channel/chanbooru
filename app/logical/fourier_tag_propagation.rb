# frozen_string_literal: true

# The tag-propagation hub. The booru is the single source of truth for a post's
# tags; any change funnels through here and fans out the PUBLIC-SAFE projection to
# every consumer (originally: Matrix state, the autotagger training feed).
# See the WHAT IS ACTUALLY WIRED note below: no projection consumer today; one
# visibility push (visibility_changed!).
#
# Private creator tags never leave the gated store: consumers only ever receive
# FourierTagSource.matrix_projection, which already excludes them. Identity-gated
# reads (the creator/mod seeing private tags) go through the pull API instead.
#
# WHAT IS ACTUALLY WIRED, as of 2026-11-23. The two sentences above describe
# the design; this paragraph describes the code, and they were not the same
# thing. Read this before believing the header.
#
#   - visibility_changed! IS wired, to every save that jails or unjails a
#     post, deletes or undeletes it, or takes a restricted (sensitive) tag on
#     or off (Post#note_jail_state_change, told after commit). For a post
#     placed in Matrix rooms (a positive posts.room_ids) it enqueues
#     PushVisibilityJob, which asks fourier-tunnel to rewrite the post's tag
#     state in those rooms (MatrixVisibilityPush). It carries no tags: the
#     tunnel rewrites what each room already holds, and Technetium reads the
#     post again and the booru's answer decides what shows. Operator
#     2026-11-22: "Misc tag changes can be on the 60s timer--jails and
#     sensitive tags should be pushes." Every other tag change reaches a
#     reader through Technetium's one-minute re-read of the pictures on
#     screen, and so does a push that is lost.
#   - fan_out! has exactly ONE caller: FourierTagSourcesController#create, the
#     provenance POST. Its callers are fourier-sampling (src/booru/client.ts)
#     and fourier-tunnel (danbooru.js) -- NOT fourier-bmb, which no longer
#     exists: no repo, no container, no checkout, and Synapse does not load
#     its registration. An ordinary tag edit -- a person on the post page, the
#     API, a tag_string update -- does NOT reach fan_out! at all.
#   - `publishers` is EMPTY. Nothing registers one anywhere in this repo;
#     MatrixTagPublisher exists only in the example line below and has never
#     been written. So publish falls through to log_publisher and the entire
#     chain produces one log line.
#
# The old comment on fan_out! said "called after any change to a post's tags",
# which was false and is the kind of false that costs somebody a day.
#
# WHY IT IS NOT WIRED TO EVERY TAG CHANGE, which is the obvious fix and the
# wrong one right now. Two reasons:
#
#   1. There is no consumer. With publishers empty, every fan-out is a job
#      that loads a post, builds a projection and writes a log line. Sampling
#      alone made 124,839 tag edits in the seven days to 2026-09-19 -- about
#      18,000 a day -- so wiring it would buy 18,000 daily log lines and a
#      queue to carry them.
#   2. Matrix no longer needs to be pushed at. Technetium reads a post's tags
#      LIVE from this booru when an image is on screen (the net.41chan.media
#      .tags state event is a POINTER carrying post_id, not a copy), so the
#      surface this hub was built to feed now pulls instead. Pushing a
#      projection at it would be a second, slower copy of what it already has.
#
# WIRE IT WHEN a real publisher exists -- a consumer that cannot pull, such as
# the autotagger training feed. Then the call belongs on the tag write path
# itself, not here, and the volume above is the number to design against.
#
# Register real publishers in an initializer, e.g.:
#   FourierTagPropagation.publishers << ->(post, proj) { MatrixTagPublisher.push(post, proj) }
# With none registered, a log publisher makes the projection observable in dev.
module FourierTagPropagation
  mattr_accessor :publishers, default: []

  # A save changed who may see `post` (see the WIRED note above). Only a post
  # placed in a Matrix room has anyone to tell; read from the row, since the
  # placements feed writes room_ids with update_all, past this instance.
  def self.visibility_changed!(post)
    rooms = Post.where(id: post.id).pick(:room_ids).to_a
    PushVisibilityJob.perform_later(post.id) if rooms.any?(&:positive?)
  end

  # Fan out one post's projection. Async so the write path stays fast.
  #
  # NOT called after every tag change -- see the note above for who calls it
  # and why it is deliberately not on the general write path.
  def self.fan_out!(post)
    PropagateTagsJob.perform_later(post.id)
  end

  def self.publish(post, projection)
    pubs = publishers.presence || [method(:log_publisher)]
    pubs.each do |pub|
      pub.call(post, projection)
    rescue StandardError => e
      Rails.logger.error("[tag-propagation] publisher #{pub} failed for post ##{post.id}: #{e.message}")
    end
  end

  def self.log_publisher(post, projection)
    Rails.logger.info("[tag-propagation] post ##{post.id} -> #{projection.to_json}")
  end
end
