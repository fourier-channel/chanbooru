# frozen_string_literal: true

# Promotion state for the landing page: which creators are showcased, and which
# one is the current feature.
#
# Timestamps rather than booleans on purpose. "Promoted" wants an order -- the
# landing page shows a handful, most recently promoted first -- and "creator of
# the month" wants history: setting a new one should not erase who it was last
# month, and the current feature is simply the latest featured_at.
class AddPromotionToCreatorGalleries < ActiveRecord::Migration[8.1]
  def change
    add_column :creator_galleries, :promoted_at, :datetime
    add_column :creator_galleries, :featured_at, :datetime

    add_index :creator_galleries, :promoted_at
    add_index :creator_galleries, :featured_at
  end
end
