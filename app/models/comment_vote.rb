# frozen_string_literal: true

class CommentVote < ApplicationRecord
  # Fork: rows name posts: a comment, which belongs to a post. Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  # Fork: a vote names its post through the comment, which
  # ApplicationRecord's write rule keyed on belongs_to :post cannot reach:
  # voting on a comment of a post hidden from the voter answers as a missing
  # comment does (Post#writable_by?, 2026-10-08).
  def refuses_write_from?(user)
    comment&.post.present? && comment.post.refuses_write_from?(user)
  end

  # And the read half, for the same reason: /comment_votes/:id, and the
  # listings -- /comment_votes and /user_actions -- named every vote on a
  # hidden post's comments (second review, 2026-10-08). Correlated through
  # the comment, for the reason ApplicationRecord.without_hidden_posts gives.
  def hidden_by_post_from?(user)
    comment&.post.present? && comment.post.hidden_from?(user)
  end

  def self.without_hidden_posts(user)
    hidden = Post.hidden_from(user)
    return all if hidden.nil?

    where.not(hidden.joins(:comments).where(Comment.arel_table[:id].eq(arel_table[:comment_id])).arel.exists)
  end

  attr_accessor :updater

  belongs_to :comment
  belongs_to :user
  has_many :mod_actions, as: :subject, dependent: :destroy

  validate :validate_vote_is_unique, if: :is_deleted_changed?
  validates :score, inclusion: { in: [-1, 1], message: "must be 1 or -1" }

  before_save :update_score_on_delete_or_undelete, if: -> { !new_record? && is_deleted_changed? }
  before_create :update_score_on_create

  deletable

  def self.visible(user)
    if user.is_moderator?
      all
    elsif user.is_anonymous?
      none
    else
      where(user: user)
    end
  end

  def self.search(params, current_user)
    q = search_attributes(params, [:id, :created_at, :updated_at, :score, :is_deleted, :comment, :user], current_user: current_user)
    q.apply_default_order(params)
  end

  def is_positive?
    score == 1
  end

  def is_negative?
    score == -1
  end

  # allow duplicate deleted votes but not duplicate active votes
  def validate_vote_is_unique
    if !is_deleted? && CommentVote.active.where.not(id: id).exists?(comment_id: comment_id, user_id: user_id)
      errors.add(:user, "have already voted for this comment")
    end
  end

  def update_score_on_create
    comment.with_lock do
      comment.update_columns(score: comment.score + score)
    end
  end

  def update_score_on_delete_or_undelete
    comment.with_lock do
      if is_deleted_changed?(from: false, to: true)
        comment.update_columns(score: comment.score - score)

        if updater != user
          ModAction.log("deleted comment vote ##{id} on comment ##{comment_id}", :comment_vote_delete, subject: self, user: updater)
        end
      else
        comment.update_columns(score: comment.score + score)

        if updater != user
          ModAction.log("undeleted comment vote ##{id} on comment ##{comment_id}", :comment_vote_undelete, subject: self, user: updater)
        end
      end
    end
  end

  def self.available_includes
    [:comment, :user]
  end
end
