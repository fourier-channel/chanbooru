# frozen_string_literal: true

module Admin
  class UsersController < ApplicationController
    def edit
      @user = authorize User.find(params[:id]), :promote?
    end

    def update
      @user = authorize User.find(params[:id]), :promote?
      return update_perk(params.expect(perk: %i[key value expires_at revoke])) if params[:perk].present?

      @level = params.dig(:user, :level)

      @user.promote_to!(@level, CurrentUser.user)

      redirect_to edit_admin_user_path(@user), notice: "User updated"
    end

    private

    # A perk granted or revoked from the edit page (UserPerk; CREATOR_TUNER.md
    # sec 4.4). UserPerk refuses anyone but an admin, so a moderator who can
    # reach this page gets a 403 here, before the perk is even looked up.
    def update_perk(perk)
      UserPerk.authorize!(CurrentUser.user)
      entry = UserPerk::PERKS[perk[:key]]
      return redirect_to edit_admin_user_path(@user), notice: "Not granted: there is no perk \"#{perk[:key]}\". The perks are: #{UserPerk::PERKS.keys.join(", ")}." if entry.nil?

      notice = if perk[:revoke].present?
        UserPerk.revoke!(@user, perk[:key], by: CurrentUser.user)
        "Revoked: #{entry[:label]} is #{entry[:default]} again."
      else
        ends = perk[:expires_at].presence && Date.iso8601(perk[:expires_at])
        UserPerk.grant!(@user, perk[:key], value: perk[:value], by: CurrentUser.user, expires_at: ends&.in_time_zone)
        "Granted: #{entry[:label]} #{perk[:value]}#{" until #{ends.iso8601}" if ends}."
      end
      redirect_to edit_admin_user_path(@user), notice: notice
    rescue Date::Error
      redirect_to edit_admin_user_path(@user), notice: "Not granted: the end date \"#{perk[:expires_at]}\" is not a date. Pick one with the date picker, or leave it empty for no end."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to edit_admin_user_path(@user), notice: "Not granted: #{e.record.errors.full_messages.join("; ")}."
    end
  end
end
