# frozen_string_literal: true

# Fan out a post's PUBLIC-SAFE tag projection to every consumer (Matrix via bmb,
# training feed). Private creator tags are already excluded by matrix_projection.
class PropagateTagsJob < ApplicationJob
  queue_as :default

  def perform(post_id)
    post = Post.find_by(id: post_id)
    return if post.nil?

    FourierTagPropagation.publish(post, FourierTagSource.matrix_projection(post))
  end
end
