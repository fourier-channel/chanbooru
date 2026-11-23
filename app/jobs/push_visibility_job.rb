# frozen_string_literal: true

# Tell the Matrix rooms a post sits in that who may see it changed
# (MatrixVisibilityPush; enqueued by FourierTagPropagation.visibility_changed!
# after the save commits). Tried again while the tunnel does not answer; once
# the tries run out the loss is logged with its fix, and Technetium's
# one-minute re-read of the pictures on screen still carries the change.
class PushVisibilityJob < ApplicationJob
  queue_as :default

  retry_on MatrixVisibilityPush::Unanswered, wait: :polynomially_longer, attempts: 5 do |job, error|
    DanbooruLogger.info("visibility push for post ##{job.arguments.first} given up after #{job.executions} tries: #{error.message}. Its rooms learn of the change from Technetium's one-minute re-read; to tell them now, run PushVisibilityJob.perform_now(#{job.arguments.first}) in a rails console once the tunnel answers")
  end

  def perform(post_id)
    MatrixVisibilityPush.new(post_id).push!
  end
end
