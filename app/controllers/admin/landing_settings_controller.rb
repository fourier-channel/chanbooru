# frozen_string_literal: true

module Admin
  # The landing carousel's console: how fast the slides move, and every
  # category's own configuration -- the "new" row's target included, which is
  # a category like the others (see LandingSetting for when that changed).
  #
  # ONE PAGE, because it is one thing an operator thinks about. The categories
  # live in their own table and save through their own action, but a carousel
  # whose speed is set on one screen and whose rows are set on another is two
  # screens describing one feature.
  class LandingSettingsController < ApplicationController
    respond_to :html

    def show
      @landing_setting = LandingSetting.current
      authorize @landing_setting
      @landing_categories = LandingCategory.configured
    end

    def update
      @landing_setting = LandingSetting.current
      authorize @landing_setting
      @landing_setting.assign_attributes(permitted_attributes(@landing_setting))
      @landing_setting.updated_by_id = CurrentUser.user.id

      if @landing_setting.save
        # Says what was saved. It used to say "The front page now shows ..."
        # about a board nothing read any more.
        redirect_to admin_landing_setting_path,
                    notice: "Each slide now holds for #{@landing_setting.advance_ms} ms."
      else
        # Re-render rather than redirect: a redirect would drop what they typed
        # and show them the old value with an error about the new one.
        flash.now[:notice] = @landing_setting.errors.full_messages.join("; ")
        @landing_categories = LandingCategory.configured
        render :show, status: 422
      end
    end

    # Every category, saved together.
    #
    # ALL OR NOTHING. A carousel with two of its three rows updated is a state
    # no one asked for and no one can see -- the page would come back looking
    # saved, with one row still on its old tags. The transaction is what makes
    # "Save" mean the whole form.
    #
    # UPSERT BY KEY, not by id. LandingCategory.configured hands the form rows
    # the database may not have yet: DEFAULTS exists precisely because a fresh
    # database never runs the migration's seed (db:prepare loads structure.sql
    # and marks every migration already-run), so the first save of a default row
    # has to CREATE it. An id-keyed form would have nothing to submit for those.
    def update_categories
      @landing_setting = LandingSetting.current
      authorize LandingCategory.new, :update?

      @landing_categories = build_categories
      saved = LandingCategory.transaction do
        @landing_categories.all?(&:save).tap { |ok| raise ActiveRecord::Rollback unless ok }
      end

      if saved
        enabled = @landing_categories.count(&:enabled?)
        redirect_to admin_landing_setting_path,
                    notice: "Carousel saved: #{enabled} of #{@landing_categories.length} categories showing."
      else
        flash.now[:notice] = category_errors.join("; ")
        render :show, status: 422
      end
    end

    private

    # The submitted rows, merged onto what is configured now.
    #
    # `kind` and `position` come from the record or from DEFAULTS and are never
    # taken from the form -- see LandingCategoryPolicy for why. A key the form
    # invents is ignored rather than created: the categories are a fixed set
    # that code dispatches on, not a list an admin may extend by typing.
    def build_categories
      submitted = params.fetch(:landing_categories, {})
      LandingCategory.configured.map do |category|
        attrs = submitted[category.key]
        next category if attrs.blank?

        category.assign_attributes(permitted_attributes(category).merge(unchecked_toggles(attrs)))
        category.updated_by_id = CurrentUser.user.id
        category
      end
    end

    # A form's unchecked checkbox submits NOTHING, so "enabled" and
    # "fresh_only" would keep their old value on every save that turned one off
    # -- a toggle that only ever switches on. Rails' check_box helper emits a
    # hidden "0" companion for exactly this, and this is the belt to that
    # braces: read them as explicitly false when absent.
    def unchecked_toggles(attrs)
      { "enabled" => attrs[:enabled].present? && attrs[:enabled] != "0",
        "fresh_only" => attrs[:fresh_only].present? && attrs[:fresh_only] != "0" }
    end

    def permitted_attributes(record)
      return super if record.is_a?(LandingSetting)

      params.require(:landing_categories)
            .require(record.key)
            .permit(*policy(record).permitted_attributes)
    end

    # Named by their row, because "Tags cannot be more than 30" on a page with
    # four tag fields is an error the admin cannot act on.
    def category_errors
      @landing_categories.reject { |c| c.errors.empty? }.flat_map do |c|
        c.errors.full_messages.map { |m| "#{c.label}: #{m}" }
      end
    end
  end
end
