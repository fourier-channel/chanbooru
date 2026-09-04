# frozen_string_literal: true

class AddGalleryPanelToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    # The gallery search panel's remembered state (operator ruling 2026-09-04:
    # the panel retains all settings between searches until the user resets
    # it). gallery_sort nil means "no opinion" -- the site default order.
    add_column :modulation_settings, :gallery_sort, :string
    add_column :modulation_settings, :gallery_view, :string, null: false, default: "unitag"
    add_column :modulation_settings, :gallery_show_deleted, :boolean, null: false, default: false
  end
end
