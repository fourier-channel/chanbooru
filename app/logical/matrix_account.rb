# frozen_string_literal: true

# The booru account that belongs to a verified Matrix identity.
#
# Every Matrix account gets a booru account with the same name (operator,
# 2026-11-07). A newcomer's first stop is Technetium, which frames the booru;
# without a booru session every picture the gate is asked for comes back 404,
# because the gate asks the booru what this viewer may see and an anonymous
# viewer may see none of it. So the first booru request that carries a verified
# identity creates the account and signs it in (SessionLoader#load_matrix_account),
# and there is no signup step and no email.
#
# The name is the Matrix localpart, exactly. A Matrix ID is unique, so nobody
# can take someone else's. When the name is already held by an account, or the
# booru cannot accept it as a name, nothing is created -- never a suffix, never
# an account attached by name alone -- and the login page says why and what to
# do (MatrixSigninComponent). The one way an existing account is linked is its
# owner signing in to it with its password while signed in to Matrix under the
# same name, and ticking the box that asks to link it (#link_signed_in).
#
# Matrix IDs are stored and compared lowercased: Synapse's localparts are, and
# a server name is a host name.
class MatrixAccount
  extend Memoist

  attr_reader :request, :matrix_id

  # @param request the HTTP request, which the new account signs in on
  # @param matrix_id [String] the verified Matrix ID (FourierIdentity.current)
  def initialize(request, matrix_id)
    @request = request
    @matrix_id = matrix_id.to_s.downcase
  end

  # @return [String, nil] the Matrix username: "alice" for "@alice:41chan.net"
  def localpart
    matrix_id[/\A@([^:]+):/, 1]
  end

  # @return [User, nil] the account linked to this Matrix ID
  memoize def linked_user
    User.find_by(matrix_id: matrix_id)
  end

  # Where this Matrix ID stands, for the login page and the session card:
  #
  # - "deleted": the account linked to it was deleted by the site staff
  #   (UserDeletion keeps the link then), so nothing is signed in or made
  # - "linked": an account is linked to it
  # - "two_factor": the account linked to it has two-factor sign-in, which a
  #   Matrix sign-in does not stand in for: it is signed in with the Matrix
  #   sign-in and its code (SessionsController#new)
  # - "available": no account is, and the Matrix username is free to take
  # - "taken": an account not linked to it already has the name
  # - "invalid": the booru cannot accept the Matrix username as a name (#name_error)
  #
  # @return [String]
  memoize def state
    if linked_user&.is_deleted?
      "deleted"
    elsif linked_user&.totp.present?
      "two_factor"
    elsif linked_user.present?
      "linked"
    elsif localpart.nil? || name_error.present?
      "invalid"
    elsif User.find_by_name(localpart).present?
      "taken"
    else
      "available"
    end
  end

  # @return [String, nil] why the booru cannot accept the Matrix username as a
  #   name, in UserNameValidator's words ("can't contain '='"), or nil when it
  #   can (or it is merely taken)
  memoize def name_error
    return "is not a Matrix username" if localpart.nil?

    User.new(name: localpart, matrix_id: matrix_id).tap(&:validate).errors.where(:name).reject { |e| e.message == "already taken" }.first&.message
  end

  # Create the account and sign it in on this request. Restricted like every
  # new account (Danbooru.config.default_user_level). Its password is random
  # and nobody is told it: the account is reached through Matrix.
  #
  # @return [User, nil] the new account, or the one a concurrent request made
  #   first; nil when the state is not "available"
  def create
    return nil unless state == "available"

    User.create!(
      request: request,
      name: localpart,
      matrix_id: matrix_id,
      password: SecureRandom.base58(32),
      level: Danbooru.config.default_user_level,
      requires_verification: false,
      last_ip_addr: request.remote_ip,
      last_logged_in_at: Time.zone.now,
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two first requests at once -- Technetium asks for a page and its
    # pictures together. The loser finds the winner's account by the link;
    # anything else that refused the account is raised, not swallowed.
    User.find_by(matrix_id: matrix_id) || raise
  end

  # Link an account its owner just signed in to and asked to link
  # (SessionsController), when the account's name is this Matrix username and
  # nothing is linked to this Matrix ID yet. This is how an account made before
  # Matrix sign-in joins it: signing in with the password while signed in to
  # Matrix proves both halves belong to one person. Never done unasked: a
  # Matrix sign-in someone else planted in the browser would take the account.
  #
  # @param user [User] the signed-in account
  # @return [Boolean] whether the account was linked
  def link_signed_in(user)
    return false if user.matrix_id.present? || linked_user.present?
    return false if localpart.nil? || !user.name.casecmp?(localpart)

    user.update_columns(matrix_id: matrix_id) # rubocop:disable Rails/SkipsModelValidations -- the link alone; an old account's name may predate today's name rules
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end
end
