# frozen_string_literal: true

# PostVersion.private_history_post_ids_hidden_from now looks up only the
# private creator tags a history search names (2026-10-13: scanning every
# private row on every search passed production's 12 s statement timeout).
# That lookup is by tag, which no index covered. Partial: only private rows
# are ever looked up this way. Concurrently, so production's table is not
# locked while it builds.
class IndexPrivateFourierTagSourcesOnTag < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :fourier_tag_sources, :tag, where: "public = false", algorithm: :concurrently,
                                          name: "index_fourier_tag_sources_on_tag_private"
  end
end
