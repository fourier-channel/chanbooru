# frozen_string_literal: true

class UserAction < ApplicationRecord
  # Fork: rows name posts: uploads, votes, approvals, flags, commentary. Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  belongs_to :model, polymorphic: true
  belongs_to :user

  attribute :model_type, :string
  attribute :model_id, :integer
  attribute :user_id, :integer
  attribute :event_type, :string
  attribute :event_at, :time

  def self.model_types
    %w[ArtistVersion ArtistCommentaryVersion Ban BulkUpdateRequest Comment
       CommentVote Dmail FavoriteGroup ForumPost ForumPostVote ForumTopic
       ModAction ModerationReport NoteVersion Post PostAppeal PostApproval
       PostDisapproval PostFlag PostReplacement PostVote SavedSearch TagAlias
       TagImplication TagVersion Upload User UserEvent UserFeedback UserUpgrade
       UserNameChangeRequest WikiPageVersion]
  end

  # Fork: each branch without the rows about posts hidden from `user`
  # (without_hidden_posts; Post's own for the uploads). The listing's own
  # rule runs on the union, which has no post column, so a moderator was
  # shown every private post's id and arrival time, and the votes and
  # comments on it (second review, 2026-10-08; CREATOR_VISIBILITY Q2).
  def self.for_user(user)
    sql = <<~SQL.squish
      (#{ArtistVersion.visible(user).without_hidden_posts(user).select("'ArtistVersion'::character varying AS model_type, id AS model_id, updater_id AS user_id, 'create'::character varying AS event_type, created_at AS event_at").to_sql})
    UNION ALL
      (#{ArtistCommentaryVersion.visible(user).without_hidden_posts(user).select("'ArtistCommentaryVersion', id, updater_id, 'create', created_at").to_sql})
    UNION ALL
      (#{Ban.visible(user).without_hidden_posts(user).select("'Ban', id, user_id, 'subject', created_at").to_sql})
    UNION ALL
      (#{BulkUpdateRequest.visible(user).without_hidden_posts(user).select("'BulkUpdateRequest', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{Comment.visible(user).without_hidden_posts(user).select("'Comment', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{CommentVote.visible(user).without_hidden_posts(user).select("'CommentVote', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{Dmail.visible(user).without_hidden_posts(user).sent.select("'Dmail', id, from_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{FavoriteGroup.visible(user).without_hidden_posts(user).select("'FavoriteGroup', id, creator_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{ForumPost.visible(user).without_hidden_posts(user).select("'ForumPost', id, creator_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{ForumPostVote.visible(user).without_hidden_posts(user).select("'ForumPostVote', id, creator_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{ForumTopic.visible(user).without_hidden_posts(user).select("'ForumTopic', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{ModAction.visible(user).without_hidden_posts(user).select("'ModAction', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{ModerationReport.visible(user).without_hidden_posts(user).select("'ModerationReport', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{NoteVersion.visible(user).without_hidden_posts(user).select("'NoteVersion', id, updater_id, 'create', created_at").to_sql})
    UNION ALL
      (#{Post.visible(user).without_hidden_posts(user).select("'Post', id, uploader_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostAppeal.visible(user).without_hidden_posts(user).select("'PostAppeal', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostApproval.visible(user).without_hidden_posts(user).select("'PostApproval', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostDisapproval.visible(user).without_hidden_posts(user).select("'PostDisapproval', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostFlag.visible(user).without_hidden_posts(user).select("'PostFlag', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostReplacement.visible(user).without_hidden_posts(user).select("'PostReplacement', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{PostVote.visible(user).without_hidden_posts(user).select("'PostVote', id, user_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{SavedSearch.visible(user).without_hidden_posts(user).select("'SavedSearch', id, user_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{TagAlias.visible(user).without_hidden_posts(user).select("'TagAlias', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{TagImplication.visible(user).without_hidden_posts(user).select("'TagImplication', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{TagVersion.visible(user).without_hidden_posts(user).select("'TagVersion', id, updater_id, 'create', created_at").where.not(updater_id: nil).order(created_at: :desc).to_sql})
    UNION ALL
      (#{Upload.visible(user).without_hidden_posts(user).select("'Upload', id, uploader_id, 'create', created_at").order(created_at: :desc).to_sql})
    UNION ALL
      (#{User.visible(user).without_hidden_posts(user).select("'User', id, id, 'create', created_at").to_sql})
    UNION ALL
      (#{UserEvent.visible(user).without_hidden_posts(user).select("'UserEvent', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{UserFeedback.visible(user).without_hidden_posts(user).select("'UserFeedback', id, creator_id, 'create', created_at").to_sql})
    UNION ALL
      (#{UserFeedback.visible(user).without_hidden_posts(user).select("'UserFeedback', id, user_id, 'subject', created_at").to_sql})
    UNION ALL (
      (#{UserUpgrade.visible(user).without_hidden_posts(user).select("'UserUpgrade', id, purchaser_id, 'create', created_at").where(status: [:complete, :refunded]).order(created_at: :desc).to_sql})
    ) UNION ALL
      (#{UserNameChangeRequest.visible(user).without_hidden_posts(user).select("'UserNameChangeRequest', id, user_id, 'create', created_at").to_sql})
    UNION ALL
      (#{WikiPageVersion.visible(user).without_hidden_posts(user).select("'WikiPageVersion', id, updater_id, 'create', created_at").to_sql})
    SQL

    from("(#{sql}) user_actions")
  end

  def self.visible(_user)
    all
  end

  def self.search(params, current_user)
    q = search_attributes(params, [:event_type, :user, :model], current_user: current_user)

    case params[:order]
    when "event_at_asc"
      q = q.order(event_at: :asc, model_id: :asc)
    else
      q = q.apply_default_order(params)
    end

    q
  end

  def self.default_order
    order(event_at: :desc, model_id: :desc)
  end

  def self.available_includes
    [:user, :model]
  end

  def readonly?
    true
  end
end
