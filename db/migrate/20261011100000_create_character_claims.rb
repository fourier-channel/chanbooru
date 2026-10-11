# frozen_string_literal: true

# A creator's claim on an original character's tag (OC ownership, ruled
# 2026-10-11): <name>_(<the creator's own slug>), kept by NAME like an
# ArtistClaim since 2026-10-07, so renaming anything moves no rights.
#
# A table of its own rather than more rows in artist_claims: an artist claim
# keys a creator's control over who sees their posts and needs an Artist row
# (artist_id is NOT NULL); a character claim hides nothing and has no Artist.
#
# One APPROVED claim per tag, at the database as well as in Ruby, so a code
# path that forgot to check still cannot write a second. Any number of
# pending, rejected or released ones may sit beside it: a refusal or a
# release must not bar asking again.
#
# Additive only (production runs db:prepare at container start and never
# reverses a schema): a new table the previous release does not read.
class CreateCharacterClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :character_claims do |t|
      t.references :creator_gallery, null: false, foreign_key: true, index: true
      t.string :tag_name, null: false
      t.string :status, null: false, default: "pending"
      t.references :approver, null: true, foreign_key: { to_table: :users }, index: false
      t.datetime :decided_at
      t.text :note, null: false, default: ""
      t.timestamps
    end

    add_index :character_claims, %i[tag_name status]
    add_index :character_claims, :tag_name, unique: true, where: "status = 'approved'",
                                            name: "index_character_claims_one_approved_per_tag"
  end
end
