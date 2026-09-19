# frozen_string_literal: true

# How many slides a row shows at once. NULL means "decide from the row": for a
# creators row, one slide per listed creator, which is what the round-robin
# gives each of them anyway; for anything else, the belt's own default.
#
# Operator, 2026-09-19: "Number of concurrent slides, defaulting to 'number of
# specified artists' but otherwise configurable." Its own migration, like
# advance_ms: rolling back the categories must not also roll back this.
class AddSlidesToLandingCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :landing_categories, :slides, :integer, null: true
  end
end
