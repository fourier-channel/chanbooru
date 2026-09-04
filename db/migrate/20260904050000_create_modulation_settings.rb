# frozen_string_literal: true

class CreateModulationSettings < ActiveRecord::Migration[8.1]
  def change
    # Sidecar per-user view state for the Modulation interface, following the
    # fourier_tag_sources pattern: rides beside the core tables rather than
    # widening upstream's users table, which keeps upstream merges clean.
    # Anonymous viewers get the same state in their Rails session instead.
    create_table :modulation_settings do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :image_cap, null: false, default: "fit" # fit | screen | none
      t.boolean :tags_expanded, null: false, default: false
      t.timestamps
    end
  end
end
