# frozen_string_literal: true

class CreateTagGrants < ActiveRecord::Migration[8.1]
  def change
    # A per-user, per-tag grant of access: the whitelist a creator (or an
    # admin on their behalf) maintains over one tag's work. This is where
    # "permissions only deny" and "access is only granted" meet (operator,
    # 2026-09-04): levels and policies keep denying by default, and a grant
    # row is the one thing that opens exactly one tag to exactly one user.
    create_table :tag_grants do |t|
      t.references :user, null: false, foreign_key: true
      t.string :tag, null: false
      t.string :ability, null: false # view | edit
      t.bigint :granted_by
      t.timestamps
    end
    add_index :tag_grants, %i[user_id tag ability], unique: true
  end
end
