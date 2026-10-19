# frozen_string_literal: true

class PasswordResetsController < ApplicationController
  respond_to :html, :xml, :json

  verify_captcha only: :create

  # Fork: given `reveal`, edit and update are the one-time password link an
  # administrator sends (PasswordReveal). Nothing they answer may be kept by a
  # cache, and the token in the page's URL may never leave in a Referer. The
  # page sends strict-origin, which keeps the path and query out of every
  # Referer, rather than no-referrer: under no-referrer a browser sends the
  # button's PUT with `Origin: null`, which Rails refuses whenever its origin
  # check is on. The password's own page has no token in its URL and sends no
  # referrer at all.
  before_action(only: %i[edit update], if: -> { params.key?(:reveal) }) do
    no_store
    response.headers["Referrer-Policy"] = (action_name == "edit") ? "strict-origin" : "no-referrer"
  end

  rescue_from PasswordReveal::Unavailable do |exception|
    render_error_page(503, exception, message: "Password links can't be opened right now. Try again in a few minutes.")
  end

  rescue_from ActiveSupport::MessageVerifier::InvalidSignature do
    redirect_to password_reset_path, notice: "Password reset link is invalid or expired. Request a new one.", status: 303
  end

  rescue_from Pundit::NotAuthorizedError do
    redirect_to profile_path, notice: "Already logged in"
  end

  # Show the password reset request page.
  def show
    authorize CurrentUser.user, policy_class: PasswordResetPolicy
  end

  # Show the change password form.
  #
  # Fork: or, given `reveal`, the page the one-time password link opens: whose
  # password it is and a button. It never uses the link up -- link previews and
  # prefetchers GET it too -- and answers a token it does not hold, used,
  # expired, replaced by a later reset or never issued alike, with the same 404.
  def edit
    if params.key?(:reveal)
      authorize CurrentUser.user, :reveal?, policy_class: PasswordResetPolicy
      @user = PasswordReveal.new.peek(params[:reveal])
      render(@user ? "reveal" : "reveal_gone", status: @user ? :ok : :not_found)
    else
      @user = authorize User.find_signed!(params.dig(:user, :signed_id), purpose: :password_reset), policy_class: PasswordResetPolicy
    end
  end

  # Send the password reset email.
  def create
    name_or_email = params.dig(:user, :name)
    @user = authorize User.find_by_name_or_email(name_or_email), policy_class: PasswordResetPolicy

    @user&.request_password_reset!(request)

    if Danbooru::EmailAddress.is_valid?(name_or_email)
      flash[:notice] = "Check your email. You will be sent a password reset link if an account with this email exists"
    else
      flash[:notice] = "Check your email. You will be sent a password reset link if this account has an email address"
    end

    redirect_to password_reset_path
  end

  # Change the user's password.
  def update
    # Fork: the one-time password link's button. The password is read and
    # deleted in one step and shown on this page, once. Everything that can
    # refuse -- the format, the rate limit -- is asked first, so a refusal
    # never uses the link up.
    if params.key?(:reveal)
      raise ActionController::UnknownFormat unless request.format.html?

      authorize CurrentUser.user, :reveal?, policy_class: PasswordResetPolicy
      @reveal = PasswordReveal.new.reveal(params[:reveal])
      @user = User.find(@reveal["user_id"]) if @reveal
      render(@reveal ? "revealed" : "reveal_gone", status: @reveal ? :ok : :not_found)
      return
    end

    @user = authorize User.find_signed!(params.dig(:user, :signed_id), purpose: :password_reset), policy_class: PasswordResetPolicy

    success = @user.reset_password(
      new_password: params.dig(:user, :password),
      password_confirmation: params.dig(:user, :password_confirmation),
      verification_code: params.dig(:user, :verification_code),
      request: request,
    )

    if success
      SessionLoader.new(request).login_user(@user, :login)
      notice = "Password updated"
    end

    respond_with(@user, notice: notice)
  end
end
