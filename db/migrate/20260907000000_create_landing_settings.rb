# frozen_string_literal: true

# Site-wide configuration for the landing carousel, so an admin can change what
# the front page shows without a deploy. One row; the model treats it as a
# singleton.
class CreateLandingSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :landing_settings do |t|
      # The board the "new" row draws from. Stored as the bare slug ("b"), not
      # a URL or a query: the panel offers structured choices so that a value
      # typed into it cannot produce a search that silently empties the row.
      t.string :board, null: false, default: "b"
      # Exclude archive-sourced posts. The sampler tags those `no_train`, so
      # their absence is the mark of a live capture.
      t.boolean :fresh_only, null: false, default: true
      t.string :label, null: false, default: "Fresh from DEGEN"
      t.integer :updated_by_id
      t.timestamps
    end
  end
end
