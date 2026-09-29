# frozen_string_literal: true

# AI generation data -- prompts, settings, workflows -- taken OUT of images the
# tunnel uploads and kept here instead (operator ruling 2026-09-28). The file
# the booru serves no longer carries it; this table is the only copy, and it is
# read by the creator of the post carrying the image and nobody else
# (FourierCreatorPrivacy, operator ruling 2026-09-29).
#
# Keyed on md5 rather than post_id because the tunnel strips BEFORE it posts:
# the md5 it sends is the md5 of the stripped bytes, which is the md5 the post
# and its media asset carry. No foreign key -- a record may arrive before the
# post it describes, and nothing about it depends on the post existing.
class CreateFourierGenerationMetadata < ActiveRecord::Migration[8.1]
  def change
    create_table :fourier_generation_metadata do |t|
      t.string :md5,    null: false
      t.string :source, null: false # "matrix" | "discord"
      t.string :poster              # an MXID, "discord:<id>", or nil
      t.jsonb  :fields, null: false # { "png:parameters" => "<original text>", ... }
      t.timestamps
    end
    add_index :fourier_generation_metadata, :md5, unique: true
  end
end
