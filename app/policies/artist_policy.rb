# frozen_string_literal: true

class ArtistPolicy < ApplicationPolicy
  # An approved claim is a second, narrower way to be allowed to edit an artist.
  #
  # It is an OR with the ordinary route, deliberately: a member who has always
  # been able to edit artists must keep being able to, and a creator gains a
  # path rather than replacing one. The narrowness is the point -- this answers
  # for exactly one artist, the one they were confirmed on.
  #
  # Ownership is read from two stored rows, never from the request. The verified
  # Matrix identity arrives as a header that no policy can see and that is
  # absent entirely from API calls; it is checked once, when the gallery is
  # made, and every question after that is a database read.
  def update?
    super || creator_of_record?
  end

  # Deletion stays where it was, and this override is load-bearing rather than
  # decorative. ApplicationPolicy defines destroy? AS update?, so widening
  # update? above silently widened deletion too -- a confirmed creator could
  # delete the artist entry they were only ever meant to be able to edit. The
  # rule for tier 5 is control over one's own tag up to but NOT including
  # deletion, so destroy? is pinned to the ordinary route explicitly.
  def destroy?
    unbanned?
  end

  def creator_of_record?
    return false if user.is_banned? || user.is_anonymous?
    return false unless manifest_permits?("artist.update")

    ArtistClaim.owner?(user, record)
  end

  def ban?
    user.is_admin? && !record.is_banned?
  end

  def unban?
    user.is_admin? && record.is_banned?
  end

  def revert?
    unbanned?
  end

  def can_view_banned?
    !user.is_anonymous?
  end

  def rate_limit_for_write(**_options)
    if user.is_builder?
      { action: "artists:write", rate: 12.0 / 1.minute, burst: 80 } # 720 per hour, 800 in first hour
    elsif user.artist_versions.exists?(created_at: ..24.hours.ago)
      { action: "artists:write", rate: 2.0 / 1.minute, burst: 30 } # 120 per hour, 150 in first hour
    else
      { action: "artists:write", rate: 1.0 / 1.5.minutes, burst: 10 } # 40 per hour, 50 in first hour
    end
  end

  def permitted_attributes
    [:name, :other_names, :other_names_string, :group_name, :url_string, :is_deleted]
  end

  def permitted_attributes_for_new
    permitted_attributes + [:source]
  end

  alias_method :show_or_new?, :show?
end
