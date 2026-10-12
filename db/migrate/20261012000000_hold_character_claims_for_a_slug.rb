# frozen_string_literal: true

# OWNERSHIP ON MOVE, before the creator has a page (operator, 2026-10-12: "at
# which point selphdestruct should be immediately assigned ownership"). A
# legacy oc_<name> tag moved onto <name>_(<q>) gives <q> an approved claim at
# once -- but a claim belongs to a CreatorGallery, and <q> may have none yet.
#
# So a claim may be HELD for a slug: status 'held', creator_gallery_id NULL,
# creator_slug the name it waits for, approver_id the approver of the move.
# The moment a gallery with that slug is made, CreatorGallery attaches it and
# approves it as that approver (CharacterClaim.take_up_held!). The smallest
# record that survives a restart and needs no job: one row, keyed by name,
# like every claim since 2026-10-07.
#
# The check constraint says it at the database: a held claim has a slug and
# no gallery; every other claim has a gallery, except a held one an admin
# withdrew before the gallery came (rejected, still keyed by its slug). So
# only a held or rejected row can lack a gallery, and nothing that reads
# pending, approved or released claims (CharacterClaim.standing, the creator
# page) can meet one. One held claim per tag, as there is one approved claim
# per tag.
#
# Additive (production runs db:prepare at container start and never reverses
# a schema): a new nullable column, a relaxed NOT NULL the previous release
# never relied on being able to break, and indexes.
class HoldCharacterClaimsForASlug < ActiveRecord::Migration[8.1]
  def change
    change_table :character_claims, bulk: true do |t|
      t.string :creator_slug
      t.change_null :creator_gallery_id, true
      t.check_constraint "(creator_gallery_id IS NOT NULL AND status <> 'held') OR " \
                         "(creator_gallery_id IS NULL AND creator_slug IS NOT NULL AND status IN ('held', 'rejected'))",
                         name: "character_claims_held_for_a_slug_or_a_gallery"
      t.index :creator_slug, where: "status = 'held'", name: "index_character_claims_held_by_slug"
      t.index :tag_name, unique: true, where: "status = 'held'", name: "index_character_claims_one_held_per_tag"
    end
  end
end
