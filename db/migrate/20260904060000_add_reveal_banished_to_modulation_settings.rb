# frozen_string_literal: true

class AddRevealBanishedToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    # Admin-only escape hatch from tag banishment (see TagBanishment): off by
    # default even for admins, by operator ruling -- revealing the banished
    # vocabulary is a deliberate act, never a side effect of rank.
    add_column :modulation_settings, :reveal_banished, :boolean, null: false, default: false
  end
end
