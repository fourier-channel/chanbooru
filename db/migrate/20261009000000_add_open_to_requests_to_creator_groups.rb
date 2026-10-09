# frozen_string_literal: true

# A creator chooses which groups visitors may ask to join (CREATOR_VISIBILITY
# Q5, ruled 2026-10-07: "a user requests to join, the creator approves or
# refuses"); a group run by hand is never named to visitors. Default false
# fails closed: no existing group is shown to anyone until its creator opens
# it from the panel.
class AddOpenToRequestsToCreatorGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :creator_groups, :open_to_requests, :boolean, null: false, default: false
  end
end
