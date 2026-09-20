# frozen_string_literal: true

# The tag-propagation hub. The booru is the single source of truth for a post's
# tags; any change funnels through here and fans out the PUBLIC-SAFE projection to
# every consumer (Matrix state via bmb, the autotagger training feed, ...).
#
# Private creator tags never leave the gated store: consumers only ever receive
# FourierTagSource.matrix_projection, which already excludes them. Identity-gated
# reads (the creator/mod seeing private tags) go through the pull API instead.
#
# WHAT IS ACTUALLY WIRED, as of 2026-09-20. The two sentences above describe
# the design; this paragraph describes the code, and they were not the same
# thing. Read this before believing the header.
#
#   - fan_out! has exactly ONE caller: FourierTagSourcesController#create, the
#     provenance POST that fourier-bmb makes. An ordinary tag edit -- a person
#     on the post page, sampling's bot, the API -- does NOT reach it.
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
