# frozen_string_literal: true

# A creator's page made private, and its Matrix contact made the creator's
# choice (operator, 2026-10-24). Every creator may have a page, so each says
# whether it is open: a private one shows a visitor its banner and avatar
# alone. "Message on Matrix" and the handle show only once turned on, for the
# pages that exist as for new ones -- so both start false.
class CreatorGalleryPrivacy < ActiveRecord::Migration[8.1]
  def change
    change_table :creator_galleries, bulk: true do |t|
      t.boolean :page_private, null: false, default: false
      t.boolean :show_contact, null: false, default: false
    end
  end
end
