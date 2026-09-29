# frozen_string_literal: true

# The md5 of the bytes the tunnel was HANDED, before it stripped them
# (shared interface v2, 2026-09-29). A record is keyed on the md5 of the
# stripped file, which is the md5 the post carries -- and that md5 moves
# whenever the strip rules change, so a re-post of the same original under
# newer rules would miss the post it duplicates. The raw md5 does not move:
# GET /fourier/generation_metadata/raw/:raw_md5.json answers "which post is
# this original" whatever the rules were when it was first posted.
#
# Set on the first write and never changed. Unique where present: one
# original is one record. Nullable only for rows written before this column
# existed (none in production, which never ran the previous migration alone).
class AddRawMd5ToFourierGenerationMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :fourier_generation_metadata, :raw_md5, :string
    add_index :fourier_generation_metadata, :raw_md5, unique: true, where: "raw_md5 IS NOT NULL"
  end
end
