# frozen_string_literal: true

# The Creator Tuner (fourier-basis docs/design/CREATOR_TUNER.md, rev 3,
# operator 2026-10-31).
#
# A harmonic is one link card a creator builds for their page. Harmonics are
# rows, not a jsonb list in the gallery's settings (operator: "we're going to
# be storing a lot of overall information"): a site taken off the list stops
# every harmonic on it from counting at once, and staff hide is a write to
# its own row, outside what the owner's Save rewrites. background_post_id has
# no foreign key on purpose: a deleted post leaves the card on its gradient.
#
# A removal is a URL staff took down, a carve-out in the site list no gallery
# may carry again. Its url is stored lowercased, the form it is matched in.
#
# A perk is a per-user server-side grant (an admin's or a paid one) that
# raises a limit, honoured only while the account is in good standing. A
# revoke is an update, so history stays; one live grant per user and perk.
#
# tuner_scan is the viewer's Scan switch. NULL is no opinion: on, unless the
# viewer's system asks for reduced motion.
class CreatorTuner < ActiveRecord::Migration[8.1]
  def change
    create_table :creator_gallery_harmonics do |t|
      t.references :creator_gallery, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.boolean :shown, null: false, default: true
      t.string :site, null: false, index: true
      t.string :url, null: false, limit: 300
      t.string :title, null: false, limit: 48
      t.string :subtitle, null: false, default: "", limit: 80
      t.string :cta
      t.jsonb :places, null: false, default: {}
      t.bigint :background_post_id
      t.integer :background_gradient, limit: 2
      t.integer :focus_x, limit: 2
      t.integer :focus_y, limit: 2
      t.integer :zoom, limit: 2
      t.integer :shade, limit: 2
      t.datetime :staff_hidden_at
      t.bigint :staff_hidden_by_id
      t.text :staff_hidden_reason
      t.timestamps
    end

    create_table :creator_harmonic_removals do |t|
      t.string :url, null: false, limit: 300, index: { unique: true }
      t.text :reason, null: false, default: ""
      t.bigint :removed_by_id, null: false
      t.bigint :source_harmonic_id
      t.timestamps
    end

    create_table :user_perks do |t|
      t.references :user, null: false, foreign_key: true
      t.string :perk, null: false
      t.integer :value, null: false
      t.string :source, null: false
      t.bigint :granted_by_id
      t.datetime :expires_at
      t.datetime :revoked_at
      t.bigint :revoked_by_id
      t.timestamps
    end
    add_index :user_perks, [:user_id, :perk], unique: true, where: "revoked_at IS NULL"

    # Scan remembered per viewer, three ways: on, off, or no opinion (nil),
    # which follows the Tuner's own default.
    add_column :modulation_settings, :tuner_scan, :boolean # rubocop:disable Rails/ThreeStateBooleanColumn
  end
end
