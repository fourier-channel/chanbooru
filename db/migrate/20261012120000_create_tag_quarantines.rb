# frozen_string_literal: true

# FLAGGED-TAG QUARANTINE (operator rulings 2026-10-12). One row per tag that
# is out of normal circulation, in one of two states:
#
#   flagged   an admin flagged it for review: every post carrying it and the
#             name itself disappear for everyone but Admin/Owner level, the
#             booru's system user, and a posting bot on its OWN posts. Not as
#             severe as banished; the review queue releases or banishes it.
#   banished  removed from the vocabulary: its posts and name exist for the
#             pipeline alone (TagBanishment), and Banish jails every carrier.
#
# A table of its own rather than a column on tags: a tags column would ride
# into TagVersion (a flag turned off would leave public "edited, nothing
# changed" rows that say it was hidden) and into /tags.json attributes. Who
# and when are kept for the queue: flagged_by/flagged_at, banished_by/
# banished_at. A banished row moved from the old config list has no
# flagged_* and is banished by the system user.
#
# Additive: a new table, nothing existing changes.
class CreateTagQuarantines < ActiveRecord::Migration[8.1]
  def change
    create_table :tag_quarantines do |t|
      t.references :tag, null: false, foreign_key: true, index: { unique: true }
      t.string :state, null: false
      t.references :flagged_by, foreign_key: { to_table: :users }
      t.datetime :flagged_at
      t.references :banished_by, foreign_key: { to_table: :users }
      t.datetime :banished_at
      t.text :note, null: false, default: ""
      t.timestamps
    end
    add_check_constraint :tag_quarantines, "state IN ('flagged','banished')", name: "tag_quarantines_state"
    add_check_constraint :tag_quarantines, "state <> 'flagged' OR flagged_at IS NOT NULL", name: "tag_quarantines_flagged_has_a_time"
    add_check_constraint :tag_quarantines, "state <> 'banished' OR banished_at IS NOT NULL", name: "tag_quarantines_banished_has_a_time"
  end
end
