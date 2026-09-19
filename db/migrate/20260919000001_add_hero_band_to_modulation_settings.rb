# frozen_string_literal: true

# The landing carousel's "Maximize Hero Band": a viewer's choice that the
# showcase should run edge to edge (operator, 2026-09-19). Remembered
# server-side like the rest of the Modulation view state, because a band that
# forgets it was maximised is a control that has to be found again every visit.
class AddHeroBandToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :modulation_settings, :hero_band, :boolean, null: false, default: false
  end
end
