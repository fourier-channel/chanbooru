# frozen_string_literal: true

# A creator's request for creator names that are not theirs by a direct match
# (operator, 2026-11-05): several names in one request, a note to the admins,
# one ticket for review. The names are artist_claims rows, each decided on its
# own; the request holds what they share, the note.
#
# by_review marks a claim filed for review rather than by the stripped-name
# match: an admin approving it is the proof, so the match is not asked of it
# again at use (ArtistClaim.refusal).
class CreateCreatorClaimRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :creator_claim_requests do |t|
      t.references :creator_gallery, null: false, foreign_key: true, index: true
      t.text :note, null: false, default: ""
      t.timestamps
    end

    add_reference :artist_claims, :creator_claim_request, null: true, foreign_key: true, index: true
    add_column :artist_claims, :by_review, :boolean, null: false, default: false
  end
end
