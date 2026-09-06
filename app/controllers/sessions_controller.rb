# frozen_string_literal: true

class SessionsController < ApplicationController
  respond_to :html

  # The booru login runs in a popup now (operator ruling 2026-09-06), and a
  # popup wants the chrome-free layout for every step of the flow -- the
  # password form, a failed attempt, and the 2FA prompt alike.
  layout -> { popup? ? "blank" : "default" }

  verify_captcha only: :create

  def new
    @session = authorize SessionLoader.new(request)
    @url = params.dig(:session, :url).presence || params[:url].presence || root_path
    # `?popup=1` is read once, here, and then carried by the form's existing
    # `url` field for the rest of the flow. Nothing else has to know.
    @url = login_done_path if params[:popup].present?

    if params[:signed_login_event].present? && @session.authorize_login_event!(params[:signed_login_event])
      notice = "New location verified. Login again to continue"
    end

    respond_with(@session, notice: notice)
  end

  # Verify the user's password and either log them in, or show them the 2FA page if they have 2FA enabled.
  def create
    @session = authorize SessionLoader.new(request)
    @user = @session.login(params.dig(:session, :name), params.dig(:session, :password))
    @url = params.dig(:session, :url).presence || params[:url].presence || root_path

    if @user&.totp.present?
      render :confirm_totp
    elsif @user
      redirect_to @url
    else
      render :new, status: 401
    end
  end

  # Ask for the user's password before sensitive actions.
  def confirm_password
    @user = CurrentUser.user
    @session = authorize SessionLoader.new(request)
    @url = params.dig(:session, :url).presence || params[:url].presence || root_path
  end

  # Verify the user's password and 2FA code before sensitive actions.
  def reauthenticate
    @user = CurrentUser.user
    @session = authorize SessionLoader.new(request)
    @url = params.dig(:session, :url).presence || params[:url].presence || root_path

    if @session.reauthenticate(@user, params.dig(:session, :password), params.dig(:session, :verification_code))
      redirect_to @url
    else
      render :confirm_password
    end
  end

  # Verify the user's 2FA code after they log in with their password.
  def verify_totp
    @user = User.find_signed(params.dig(:totp, :user_id), purpose: :verify_totp)
    @url = params.dig(:totp, :url).presence || root_url
    @session = authorize SessionLoader.new(request)

    if @session.verify_totp!(@user, params.dig(:totp, :code))
      redirect_to @url
    else
      @user.totp.errors.add(:code, "is incorrect")
      render :confirm_totp
    end
  end

  def destroy
    @session = authorize SessionLoader.new(request)
    @session.logout(CurrentUser.user)
    redirect_to root_path, notice: "You are now logged out", status: 303
  end

  # Deprecated (operator ruling 2026-09-06). 404, not 403, and 404 for the same
  # reason a retired section does: a 403 confirms there is a page there.
  def logout
    raise ActiveRecord::RecordNotFound if Danbooru.config.logout_page_retired? && !CurrentUser.user.is_owner?

    @session = authorize SessionLoader.new(request)
    render layout: "blank"
  end

  # The end of a popup login: close the window and let the opener notice. The
  # opener is watching for its own focus event, so there is nothing to post
  # back -- and nothing here depends on the popup and the opener sharing an
  # origin beyond the same-origin they already share.
  #
  # If the window was NOT opened by script, window.close() is a no-op, so the
  # page also says what happened and offers the way back rather than sitting
  # blank forever.
  def done
    skip_authorization
  end

  private

  # A popup login is identified by where it is GOING, not by a flag threaded
  # through two separate forms. /login/done is only ever a popup's destination.
  def popup?
    action_name == "done" || @url.to_s == login_done_path
  end
end
