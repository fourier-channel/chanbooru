# frozen_string_literal: true

class UsersController < ApplicationController
  respond_to :html, :xml, :json

  around_action :set_timeout, only: [:profile, :show]
  verify_captcha only: :create

  def index
    if params[:name].present?
      params[:search] ||= {}
      params[:search][:name_or_past_name_matches] = params[:name]
      params[:redirect] = "true"
    end

    @users = authorize User.paginated_search(params)
    @users = @users.includes(:inviter) if request.format.html?

    if params[:variant] == "tooltip" && !@users.load.one?
      render status: 404
    else
      respond_with(@users)
    end
  end

  def show
    @user = authorize User.find(params[:id])
    respond_with(@user, methods: @user.full_attributes) do |format|
      format.html.tooltip { render layout: false }
    end
  end

  def new
    @user = authorize User.new
    @url = params.dig(:user, :url).presence || params[:url].presence || root_path
    respond_with(@user)
  end

  def edit
    @user = authorize User.find(params[:id])
    respond_with(@user)
  end

  def settings
    @user = authorize CurrentUser.user

    if @user.is_anonymous?
      redirect_to login_path(url: settings_path)
    else
      params[:action] = "edit"
      respond_with(@user, template: "users/edit")
    end
  end

  def profile
    @user = authorize CurrentUser.user

    if !@user.is_anonymous? || request.format.json? || request.format.xml?
      params[:action] = "show"
      respond_with(@user, methods: @user.full_attributes, template: "users/show")
    else
      redirect_to login_path(url: profile_path)
    end
  end

  def create
    user_signup = UserSignup.new(request)
    @user = authorize(user_signup.user)
    @url = params.dig(:user, :url).presence || params[:url].presence

    if save_with_token(@user)
      set_current_user
    end

    respond_with(@user, location: @url)
  end

  # Create the account and spend the registration token together, or neither.
  #
  # One transaction on purpose. Spending first and saving after would burn a use
  # on a signup that then failed validation; saving first and spending after
  # would hand out an account on a token that had run out in between. Rolling
  # the pair back together is the only version with no window.
  #
  # A nil token means open signup, which on this fork is the test environment
  # only -- in production the policy has already refused a tokenless POST with
  # a 403, so this branch is not a way in.
  def save_with_token(user)
    token = user.respond_to?(:signup_token_record) ? user.signup_token_record : nil
    return user.save(context: [:create, :deliverable]) if token.nil?

    saved = false
    ActiveRecord::Base.transaction do
      token.redeem!
      saved = user.save(context: [:create, :deliverable])
      raise ActiveRecord::Rollback unless saved
    end
    saved
  rescue SignupToken::InvalidTokenError => e
    # Lost the race for the last use, between the policy check and here.
    user.errors.add(:base, "Registration token: #{e.message}")
    false
  end

  def update
    @user = authorize User.find(params[:id])
    @user.update(permitted_attributes(@user))

    respond_with(@user, notice: "Settings updated") do |format|
      format.html { redirect_back fallback_location: edit_user_path(@user) }
    end
  end

  def promote
    @user = authorize User.find(params[:id])
    respond_with(@user)
  end

  def demote
    @user = authorize User.find(params[:id])
    respond_with(@user)
  end

  def deactivate
    if params[:id].present?
      @user = authorize User.find(params[:id])
    else
      @user = authorize CurrentUser.user
    end

    respond_with(@user)
  end

  def destroy
    @user = authorize User.find(params[:id])

    user_deletion = UserDeletion.new(user: @user, deleter: CurrentUser.user, password: params.dig(:user, :password), request: request)
    user_deletion.delete!

    if user_deletion.errors.none?
      respond_with(user_deletion, notice: "Account deactivated", location: posts_path)
    else
      flash[:notice] = user_deletion.errors.full_messages.join("; ")
      redirect_to deactivate_user_path(@user)
    end
  end

  def custom_style
    @user = authorize CurrentUser.user
    @custom_css = @user.custom_css
    expires_in 10.years
  end

  private

  def set_timeout
    PostVersion.connection.execute("SET statement_timeout = #{CurrentUser.user.statement_timeout}")
    yield
  ensure
    PostVersion.connection.execute("SET statement_timeout = 0")
  end

  def item_matches_params(user)
    if params[:search][:name_matches]
      User.normalize_name(user.name) == User.normalize_name(params[:search][:name_matches])
    else
      true
    end
  end
end
