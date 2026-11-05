# frozen_string_literal: true

# Fourier's tours of the Creator Identity dashboard, per account (operator,
# 2026-11-05: a tour "that can be skipped, but also re-run later if desired";
# the creator-name and OC tours "are independent"). One hash by tour:
# {"creator_name" => "done", "oc" => "skipped"}. A tour with no entry has not
# been finished or skipped, so it plays; forgetting the entry is the replay.
class AddToursToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :modulation_settings, :tours, :jsonb, null: false, default: {}
  end
end
