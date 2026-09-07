# frozen_string_literal: true

module Admin
  # The front page's "new" row, editable without a deploy.
  class LandingSettingsController < ApplicationController
    respond_to :html

    def show
      @landing_setting = LandingSetting.current
      authorize @landing_setting
    end

    def update
      @landing_setting = LandingSetting.current
      authorize @landing_setting
      @landing_setting.assign_attributes(permitted_attributes(@landing_setting))
      @landing_setting.updated_by_id = CurrentUser.user.id

      if @landing_setting.save
        redirect_to admin_landing_setting_path,
                    notice: "The front page now shows #{@landing_setting.label} (/#{@landing_setting.board}/)."
      else
        # Re-render rather than redirect: a redirect would drop what they typed
        # and show them the old value with an error about the new one.
        flash.now[:notice] = @landing_setting.errors.full_messages.join("; ")
        render :show, status: :unprocessable_entity
      end
    end
  end
end
