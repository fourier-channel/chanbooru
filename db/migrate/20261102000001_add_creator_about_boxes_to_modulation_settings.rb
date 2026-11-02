# frozen_string_literal: true

# A creator gallery's About boxes, per viewer (operator, 2026-11-02: "Allow
# each viewer to resize the boxes vertically"; each box "opened and closed
# individually"). One hash for every gallery, by box kind:
# {"bio" => {"open" => false, "h" => 320}}. A kind with no entry is open at
# its content's height, so the empty hash is no opinion about any box.
class AddCreatorAboutBoxesToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :modulation_settings, :creator_about_boxes, :jsonb, null: false, default: {}
  end
end
