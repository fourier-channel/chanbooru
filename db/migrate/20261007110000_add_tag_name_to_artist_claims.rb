# frozen_string_literal: true

# A claim is on a TAG, not on an Artist row (design CREATOR_VISIBILITY section
# 9, ruled 2026-10-07).
#
# Keyed on artist_id, an approved claim followed the Artist's CURRENT name, and
# any unbanned member can rename an Artist: rename the claimed entry to another
# creator's tag and the claim -- and the control over posts it is about to
# confer -- moved onto that creator's posts. tag_name is copied from the artist
# when the claim is filed and never changes (ArtistClaim), so a rename moves
# nothing. artist_id stays: the claim still links to the entry it was filed
# against, and artist editing (ArtistClaim.owner?) still reads it.
#
# Additive only. Production runs db:prepare at container start and --rollback
# never reverses a schema, so the column is nullable (the previous release
# writes no claims, but must still boot against this schema), the backfill is
# raw SQL, and the old per-artist index is kept beside the new per-tag one.
#
# The backfill cannot trip the new unique index: artists.name is unique and at
# most one claim per artist is approved, so at most one approved claim per
# name exists to copy.
#
# lower(fourier_post_creators.mxid) is what CreatorControl looks a creator's
# recorded posts up by -- case-insensitively, as FourierIdentity compares --
# and only post_id was indexed.
class AddTagNameToArtistClaims < ActiveRecord::Migration[8.1]
  def up
    add_column :artist_claims, :tag_name, :string

    execute <<~SQL.squish
      UPDATE artist_claims SET tag_name = artists.name
      FROM artists
      WHERE artists.id = artist_claims.artist_id AND artist_claims.tag_name IS NULL
    SQL

    add_index :artist_claims, :tag_name, unique: true, where: "status = 'approved'",
                                         name: "index_artist_claims_one_approved_per_tag_name"
    add_index :fourier_post_creators, "lower(mxid)", name: "index_fourier_post_creators_on_lower_mxid"
  end

  def down
    remove_index :fourier_post_creators, name: "index_fourier_post_creators_on_lower_mxid"
    remove_index :artist_claims, name: "index_artist_claims_one_approved_per_tag_name"
    remove_column :artist_claims, :tag_name
  end
end
