# frozen_string_literal: true

# Fan out a post's PUBLIC-SAFE tag projection to every consumer. Private creator
# tags are already excluded by matrix_projection.
#
# "Every consumer" is currently NONE: FourierTagPropagation.publishers is empty
# and publish falls through to a log line. See that module's header for who
# calls this and why it is not on the general tag-write path.
class PropagateTagsJob < ApplicationJob
  queue_as :default

  def perform(post_id)
    post = Post.find_by(id: post_id)
    return if post.nil?

    FourierTagPropagation.publish(post, FourierTagSource.matrix_projection(post))
  end
end
