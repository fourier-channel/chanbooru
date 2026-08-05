# frozen_string_literal: true

class AddPublicToFourierTagSources < ActiveRecord::Migration[8.1]
  def change
    # Whether this provenance row may appear in PUBLIC projections (the Matrix
    # state event, anonymous booru views). Creator-only (prompt-derived) tags
    # default to private; auto/both/meta/human are public.
    add_column :fourier_tag_sources, :public, :boolean, null: false, default: true
    add_index :fourier_tag_sources, [:post_id, :public]
  end
end
