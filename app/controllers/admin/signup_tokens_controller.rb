# frozen_string_literal: true

module Admin
  # Registration tokens: who may make an account here.
  #
  # 41chan is invite-only, and this is the invite. A token can be single use,
  # limited, or unlimited, and can expire -- the same choices MAS offers on the
  # Matrix side, deliberately, so the two halves of the site behave alike.
  class SignupTokensController < ApplicationController
    respond_to :html

    def index
      authorize SignupToken
      @signup_tokens = SignupToken.order(revoked_at: :asc, created_at: :desc)
    end

    def create
      authorize SignupToken
      @signup_token = SignupToken.new(permitted_attributes(SignupToken))
      @signup_token.creator = CurrentUser.user
      # Blank means "generate one"; the model's default handles it.
      @signup_token.token = SignupToken.generate_token if @signup_token.token.blank?

      if @signup_token.save
        redirect_to admin_signup_tokens_path, notice: "Invite code #{@signup_token.token} created."
      else
        flash[:notice] = @signup_token.errors.full_messages.join("; ")
        redirect_to admin_signup_tokens_path
      end
    end

    # Revoked rather than deleted: a spent or leaked code stays in the list with
    # its history, so "who let this person in" remains answerable.
    def revoke
      @signup_token = authorize SignupToken.find(params[:id])
      @signup_token.revoke!(by: CurrentUser.user)
      redirect_to admin_signup_tokens_path, notice: "Invite code revoked."
    end
  end
end
