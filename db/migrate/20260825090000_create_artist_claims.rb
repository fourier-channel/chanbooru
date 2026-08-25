# frozen_string_literal: true

# A creator asserting that an artist tag is theirs, and a moderator agreeing.
#
# A table rather than a column on creator_galleries, because a claim has a life
# before it has an answer: T7 approves these, so "pending" has to be
# representable, and a rejection has to be distinguishable from never having
# asked. A foreign key alone can only say "linked" or "not linked".
#
# The uniqueness rule is deliberately narrow. Only one APPROVED claim may exist
# per artist -- two people cannot both own a tag -- but any number of pending or
# rejected ones may, because a rejection must not silently bar the person from
# ever asking again, and two creators may genuinely both believe a tag is
# theirs until someone rules.
class CreateArtistClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :artist_claims do |t|
      t.references :artist, null: false, foreign_key: true, index: true
      t.references :creator_gallery, null: false, foreign_key: true, index: true
      t.string :status, null: false, default: "pending"
      t.bigint :approver_id
      t.datetime :decided_at
      t.text :note, null: false, default: ""
      t.timestamps
    end

    add_index :artist_claims, :status
    add_index :artist_claims, %i[artist_id status]
    # The rule that matters, at the database rather than only in Ruby: a second
    # approved claim on the same artist cannot be written even by a code path
    # that forgot to check.
    add_index :artist_claims, :artist_id, unique: true, where: "status = 'approved'",
                                          name: "index_artist_claims_one_approved_per_artist"
  end
end
