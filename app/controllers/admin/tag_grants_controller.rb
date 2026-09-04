# frozen_string_literal: true

module Admin
  # Managing TagGrants from the user-edit console. Gated exactly like the
  # console itself (UserPolicy#promote?): whoever may change what a user IS
  # may change what they are granted.
  class TagGrantsController < ApplicationController
    def create
      user = User.find(params[:user_id])
      authorize user, :promote?, policy_class: UserPolicy

      grant = TagGrant.new(user: user, tag: params[:tag], ability: params[:ability], granted_by: CurrentUser.user.id)
      if grant.save
        redirect_to edit_admin_user_path(user), notice: "Granted #{grant.ability} on #{grant.tag}"
      else
        redirect_to edit_admin_user_path(user), notice: "Not granted: #{grant.errors.full_messages.join('; ')}"
      end
    end

    def destroy
      grant = TagGrant.find(params[:id])
      authorize grant.user, :promote?, policy_class: UserPolicy

      grant.destroy!
      redirect_to edit_admin_user_path(grant.user), notice: "Revoked #{grant.ability} on #{grant.tag}"
    end
  end
end
