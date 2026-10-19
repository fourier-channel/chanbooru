# frozen_string_literal: true

class BulkUpdateRequestPolicy < ApplicationPolicy
  def create?
    unbanned? && (record.forum_topic.blank? || policy(record.forum_topic).reply?)
  end

  def update?
    return false if !unbanned? || record.is_approved?

    user.is_admin? || (record.user_id == user.id && !record.has_too_many_votes_to_edit?)
  end

  def approve?(tags: nil)
    return false if !unbanned? || record.is_approved?
    # Fork: a posting bot files requests for people and approves none,
    # whatever its level -- tunnel is an Approver, which clears a small
    # artist alias (operator, 2026-10-19). Asked by name: may_post? says
    # yes to every account where posting is not restricted to the bots.
    return false if FourierCreatorPrivacy.posting_bot?(user)
    # Fork: approval_level is BUILDER, MODERATOR or ADMIN (Command#approval_level),
    # and asking it looks up each alias and implication line's tags and
    # claims. Where the level alone decides -- an admin passes every one, an
    # account below Builder none -- it is not asked: can_approve is served
    # on every row of a listing.
    return true if user.level >= User::Levels::ADMIN
    return false if user.level < User::Levels::BUILDER

    user.level >= record.approval_level(tags:)
  end

  def destroy?
    return false if !unbanned? || record.is_approved?

    record.is_pending? && (user.is_admin? || record.user_id == user.id)
  end

  def can_update_forum?
    user.is_admin?
  end

  def rate_limit_for_write(**_options)
    if record.invalid?
      { action: "bulk_update_requests:write:invalid", rate: 1.0 / 1.second, burst: 1 }
    elsif user.is_admin?
      { action: "bulk_update_requests:write", rate: 1.0 / 1.second, burst: 50 }
    elsif user.is_builder?
      { action: "bulk_update_requests:write", rate: 1.0 / 1.minute, burst: 20 }
    elsif user.bulk_update_requests.exists?(created_at: ..4.hours.ago)
      { action: "bulk_update_requests:write", rate: 1.0 / 1.minute, burst: 20 }
    else
      { action: "bulk_update_requests:write", rate: 1.0 / 1.minute, burst: 5 }
    end
  end

  def permitted_attributes_for_create
    [:script, :title, :reason, :forum_topic_id]
  end

  # Fork: what this viewer may do with the request (BulkUpdateRequest#can_approve,
  # #can_reject), which the Technetium card renders its buttons from; and
  # the record of its last run as this viewer may read it (#lines,
  # #skipped_count, #failed_line) IN PLACE OF the raw results column, which
  # holds the id of every post the run skipped, hidden ones included.
  def api_attributes
    super - [:results] + %i[lines skipped_count failed_line can_approve can_reject]
  end

  def permitted_attributes_for_update
    if can_update_forum?
      [:script, :forum_topic_id, :forum_post_id]
    else
      [:script]
    end
  end
end
