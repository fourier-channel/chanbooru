# frozen_string_literal: true

# Two viewer choices from the operator's creator gallery list (2026-11-01),
# remembered server-side like the rest of the Modulation view state.
#
# wheel_scroll: the hero band's mouse wheel steps the belt only once the
# viewer turns it on. Off by default, because a band that takes the wheel
# "catches attempts to scroll down the page". One setting for every hero band.
#
# creator_about_open: a creator gallery's About panel, open by default ("Start
# 'About' expanded by default"); one value for all galleries.
class AddWheelScrollAndCreatorAboutOpenToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    change_table :modulation_settings, bulk: true do |t|
      t.boolean :wheel_scroll, null: false, default: false
      t.boolean :creator_about_open, null: false, default: true
    end
  end
end
