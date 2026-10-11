# frozen_string_literal: true

# The error page's pictures (operator, 2026-10-11): booru posts chosen on the
# landing console, one drawn at random on each load of the "Oh No!" page.
# Additive, and empty by default, so the page draws its placeholder until
# someone picks posts.
class AddErrorPagePostIdsToLandingSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :landing_settings, :error_page_post_ids, :integer, array: true, null: false, default: []
  end
end
