# frozen_string_literal: true

# The tag-propagation hub. The booru is the single source of truth for a post's
# tags; any change funnels through here and fans out the PUBLIC-SAFE projection to
# every consumer (Matrix state via bmb, the autotagger training feed, ...).
#
# Private creator tags never leave the gated store: consumers only ever receive
# FourierTagSource.matrix_projection, which already excludes them. Identity-gated
# reads (the creator/mod seeing private tags) go through the pull API instead.
#
# Register real publishers in an initializer, e.g.:
#   FourierTagPropagation.publishers << ->(post, proj) { MatrixTagPublisher.push(post, proj) }
# With none registered, a log publisher makes the projection observable in dev.
module FourierTagPropagation
  mattr_accessor :publishers, default: []

  # Called after any change to a post's tags. Async so the write path stays fast.
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
