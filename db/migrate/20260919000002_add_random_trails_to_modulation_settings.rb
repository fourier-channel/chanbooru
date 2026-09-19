# frozen_string_literal: true

# Random mode's history (operator, 2026-09-19: "I just reinvented a history").
# One trail per search, per viewer: the posts random has shown, in the order
# they were shown, so walking back retraces exact footsteps and only walking
# past the frontier rolls a new post. Anonymous viewers keep theirs in the
# session; signed-in viewers keep them here, with the rest of their view state.
class AddRandomTrailsToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :modulation_settings, :random_trails, :jsonb, null: false, default: {}
  end
end
