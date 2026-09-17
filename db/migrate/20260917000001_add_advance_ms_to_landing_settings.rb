# frozen_string_literal: true

# How long a slide holds before the next one. It was hardcoded at 6000 in
# ModulationLandingComponent#config and is a thing the operator asked to be
# able to set.
#
# A separate migration from the category table on purpose: rolling back the
# categories must not also roll back the speed control.
class AddAdvanceMsToLandingSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :landing_settings, :advance_ms, :integer, null: false, default: 6000
  end
end
