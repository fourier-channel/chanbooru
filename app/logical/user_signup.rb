# frozen_string_literal: true

# This class handles the creation of new accounts. It checks whether the account should be restricted because the signup
# was from a proxy or a sockpuppet account.
class UserSignup
  extend Memoist

  attr_reader :request, :params

  # @param request the HTTP request
  def initialize(request)
    @request = request
    @params = request.params
  end

  # @return [User] The user that will be created.
  memoize def user
    User.new(
      request: request,
      last_ip_addr: request.remote_ip,
      last_logged_in_at: Time.zone.now,
      requires_verification: requires_verification?,
      level: initial_level,
      name: params[:user][:name],
      password: params[:user][:password],
      password_confirmation: params[:user][:password_confirmation],
      # Fork: no email where the emails section is retired (41chan keeps none).
      email_address_attributes: (Danbooru.config.retired_sections.include?("emails") ? {} : { address: params.dig(:user, :email_address, :address) }),
      matrix_id: matrix_id,
      # Not persisted. The policy reads it to decide whether this signup is
      # permitted at all; see User#signup_token_record.
      signup_token: params.dig(:user, :signup_token),
    )
  end

  # Fork: the verified Matrix ID this account is made for, when the viewer has
  # one and no account is linked to it yet. Usually that account was made
  # already, under the Matrix username (MatrixAccount); this is the account of
  # a viewer whose Matrix username was taken or not a usable name, who chose
  # another one here. Taken from the verified identity, never from a param.
  # UserPolicy#create? lets it in without an invite code: Matrix sign-in is
  # the invitation.
  #
  # @return [String, nil]
  memoize def matrix_id
    return nil unless Danbooru.config.matrix_accounts_from_identity?

    identity = FourierIdentity.current(request)
    return nil if identity.blank?

    account = MatrixAccount.new(request, identity)
    account.matrix_id if account.linked_user.nil?
  end

  # Returns true if the new account should be restricted. Signups from local
  # IPs are unrestricted so that verification isn't required for development,
  # testing, or personal boorus.
  def requires_verification?
    return false if !Danbooru.config.new_user_verification?.to_s.truthy?
    return false if ip_address.is_local?

    # we check for IP bans first to make sure we bump the IP ban hit count
    is_ip_banned? || is_sockpuppet? || is_recently_used_ip? || is_proxy?
  end

  # Fork: an unflagged signup starts at Danbooru.config.default_user_level, not
  # upstream's Member -- Restricted on this site, so full browsing is granted by
  # a promotion, never had by signing up (operator, 2026-10-19). A signup
  # verification flags is Restricted whatever the default.
  #
  # @return [Integer] the level the new account starts at
  def initial_level
    if requires_verification?
      User::Levels::RESTRICTED
    else
      Danbooru.config.default_user_level
    end
  end

  private

  def ip_address
    @ip_address ||= Danbooru::IpAddress.new(request.remote_ip)
  end

  memoize def is_recently_used_ip?
    User.where(last_logged_in_at: 24.hours.ago..).exists?(["last_ip_addr <<= ?", ip_address.subnet.to_s]) ||
      UserEvent.authorized.where(created_at: 24.hours.ago..).exists?(["ip_addr <<= ?", ip_address.subnet.to_s])
  end

  memoize def is_sockpuppet?
    UserEvent.authorized.exists?(session_id: request.session[:session_id])
  end

  memoize def is_ip_banned?
    IpBan.hit!(:partial, ip_address.to_s)
  end

  memoize def is_proxy?
    ip_address.is_proxy?
  end
end
