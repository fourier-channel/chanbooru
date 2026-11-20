# frozen_string_literal: true

class UserNameChangeRequest < ApplicationRecord
  belongs_to :user

  attr_accessor :updater, :is_deletion

  validate :not_limited, on: :create
  validate :pinned_names_stay_put, on: :create
  validates :original_name, presence: true
  validates :desired_name, presence: true, user_name: true, matrix_username: true, on: :create, unless: :is_deletion

  after_create :update_name!
  after_create :create_mod_action
  after_create :send_dmail
  # A rename of the jail's account moves Post.untagged_jailed_ids, which
  # reads the names an account held (Post.jail_deletions).
  after_commit -> { Post.jail_state_changed! }, on: :create

  def self.visible(user)
    if user.is_moderator?
      all
    elsif user.is_anonymous?
      none
    else
      where(user: User.undeleted)
    end
  end

  def self.search(params, current_user)
    q = search_attributes(params, [:id, :created_at, :updated_at, :user, :original_name, :desired_name], current_user: current_user)

    if params[:old_name].present?
      q = q.where("lower(original_name) = ?", User.normalize_name(params[:old_name]))
    end

    if params[:new_name].present?
      q = q.where("lower(desired_name) = ?", User.normalize_name(params[:new_name]))
    end

    q.apply_default_order(params)
  end

  def update_name!
    user.update!(name: desired_name)
  end

  # A name that carries authority (User.pinned_names) stays on its account:
  # nobody but the site owner renames that account, or gives the name to
  # another (boo.122 B). Compared normalized, so "Tunnel" is "tunnel". A
  # deletion's rename is UserDeletion's to refuse (#validate_deletion), where
  # the refusal is an error on the page rather than a 500 mid-deletion.
  def pinned_names_stay_put
    return if updater&.is_owner? || is_deletion

    pinned = User.pinned_names
    taken = [user&.name, original_name, desired_name].compact.map { |name| User.normalize_name(name) }.find { |name| name.in?(pinned) }
    return if taken.nil?

    errors.add(:base, "#{taken} is one of the booru's own account names (the jail panel, a posting bot or the system user): only the site owner renames that account or gives its name to another. Ask the site owner")
  end

  def not_limited
    return if is_deletion
    return if user.name_invalid?
    return if updater && updater != user

    if user.user_name_change_requests.exists?(created_at: (1.week.ago..))
      errors.add(:base, "You can only submit one name change request per week")
    end
  end

  def create_mod_action
    return if updater.nil? || user == updater
    ModAction.log("changed user ##{user.id}'s name from #{original_name} to #{desired_name}", :user_name_change, subject: user, user: updater)
  end

  def send_dmail
    return if updater.nil? || user == updater
    Dmail.create_automated(to: user, disable_email_notifications: true, title: "Your username has been changed", body: <<~EOS)
      Your username has been changed from #{original_name} to #{desired_name}. Your old name was either no longer valid or it violated site rules. You can change it to something else after one week. Please make sure your name follows the [[help:community rules|community rules]].
    EOS
  end
end
