# frozen_string_literal: true

# Delete a user's account. Deleting an account really just deactivates the
# account, it doesn't fully delete the user from the database. It wipes their
# username, password, account settings, favorites, and saved searches, and logs
# the deletion.
class UserDeletion
  include ActiveModel::Validations

  attr_reader :user, :deleter, :password, :verification_code, :request

  validate :validate_deletion

  # Initialize a user deletion.
  #
  # @param user [User] the user to delete
  # @param deleter [User] the user performing the deletion
  # @param password [String] the user's password (for confirmation)
  # @param verification_code [String] the 2FA code or a backup code, asked of a
  #   2FA account whose Matrix sign-in stands in for its password
  # @param request the HTTP request (for logging the deletion in the user event log)
  def initialize(user:, deleter: user, password: nil, verification_code: nil, request: nil)
    @user = user
    @deleter = deleter
    @password = password
    @verification_code = verification_code
    @request = request
  end

  # Delete the account, if the deletion is allowed.
  #
  # @return [Boolean] True if the deletion was successful, false otherwise.
  def delete!
    return false if invalid?

    user.with_lock do
      rename
      reset_password
      async_delete_user

      if user == deleter
        UserEvent.create_from_request!(user, :user_deletion, request)
        SessionLoader.new(request).logout(user)
        # Fork: the deleted account's name and Matrix link are gone, so the
        # next request would make a new account under the Matrix username and
        # sign it in (SessionLoader#load_matrix_account), undoing the deletion
        # the viewer just asked for. Held back as a sign-out is, until they
        # ask for a new account from the login page. Set after the logout,
        # which empties the session.
        matrix_id = Danbooru.config.matrix_accounts_from_identity? && FourierIdentity.current(request)
        request.session[:matrix_signed_out] = matrix_id.downcase if matrix_id.present?
      else
        ModAction.log("deleted user ##{user.id}", :user_delete, subject: user, user: deleter)
      end
    end

    true
  end

  def undelete!
    user.with_lock do
      user.update!(is_deleted: false, password: password)
      UserNameChangeRequest.create!(user: user, desired_name: user.user_name_change_requests.order(id: :desc).first.original_name, original_name: user.name)
      ModAction.log("undeleted user ##{user.id}", :user_undelete, subject: user, user: deleter)
      UserEvent.create_from_request!(user, :user_undeletion, request) if request.present?
    end
  end

  # Calls `delete_user`.
  def async_delete_user
    DeleteUserJob.perform_later(user)
  end

  def delete_user
    delete_user_data
    delete_user_settings
  end

  def delete_user_data
    user.api_keys.destroy_all
    user.forum_topic_visits.destroy_all
    user.saved_searches.destroy_all
    user.favorite_groups.is_private.destroy_all
    user.login_sessions.active.find_each(&:revoke!)

    user.post_votes.active.negative.find_each do |vote|
      vote.soft_delete!(updater: user)
    end

    if user.enable_private_favorites
      user.favorites.destroy_all
      user.post_votes.active.positive.find_each do |vote|
        vote.soft_delete!(updater: user)
      end
    end
  end

  def delete_user_settings
    user.email_address = nil
    user.last_logged_in_at = nil
    user.last_forum_read_at = nil
    user.totp_secret = nil
    user.backup_codes = nil

    User::USER_PREFERENCE_BOOLEAN_ATTRIBUTES.each do |attribute|
      user.send("#{attribute}=", false)
    end

    %w[time_zone comment_threshold default_image_size favorite_tags blacklisted_tags custom_style per_page theme].each do |attribute|
      user[attribute] = User.column_defaults[attribute]
    end

    user.save!
  end

  # Fork: deleting your own account unlinks it now with the name, not later
  # with the settings (DeleteUserJob), so the Matrix account can have a new
  # booru account under that name (MatrixAccount) rather than meet a deleted
  # one. An account the site staff delete keeps the link: otherwise the next
  # request would make a new account under the freed name, and #undelete!
  # could not give the name back.
  def reset_password
    user.update!(is_deleted: true, password: SecureRandom.hex(16), matrix_id: (user.matrix_id unless user == deleter))
  end

  def rename
    UserNameChangeRequest.create!(user: user, desired_name: "user_#{user.id}", original_name: user.name, is_deletion: true)
  end

  def validate_deletion
    if user == deleter
      # Fork: the Matrix sign-in stands in for the password, not for a second
      # factor, as in SessionLoader#reauthenticate.
      if user.matrix_verified?(request) && user.totp.present?
        if !user.totp.verify(verification_code) && !user.verify_backup_code!(verification_code)
          errors.add(:base, "Two-factor code is incorrect: enter the 6-digit code from your authenticator app, or a backup code")
        end
      elsif !user.authenticate_password(password) && !user.matrix_verified?(request)
        errors.add(:base, "Password is incorrect")
      end

      if user.is_moderator?
        errors.add(:base, "#{user.level_string.pluralize} cannot delete their account")
      end

      if user.is_banned?
        errors.add(:base, "You cannot delete your account if you are banned")
      end
    else
      if !user.policy(deleter).deactivate?
        errors.add(:base, "You cannot delete an account belonging to another user")
      end

      if user.is_gold?
        errors.add(:base, "You cannot delete a privileged account")
      end
    end
  end
end
