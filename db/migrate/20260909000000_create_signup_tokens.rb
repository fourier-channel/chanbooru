# frozen_string_literal: true

# Registration tokens: an account may be created only by someone holding one.
#
# Deliberately the same shape as MAS's user_registration_tokens, which is what
# gates registration on the Matrix side, so the two halves of 41chan are
# explained by one idea rather than two. On the Matrix side the live token is a
# single unlimited string handed to people the operator trusts; nothing here
# assumes that, but it supports it.
class CreateSignupTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :signup_tokens do |t|
      # The secret itself. Operator-chosen or generated; unique so redemption
      # can look it up without ambiguity.
      t.string :token, null: false
      # What it is for, so a list of tokens is readable a month later.
      t.string :note, null: false, default: ""
      # NULL means unlimited, matching MAS's --unlimited. A number caps it.
      t.integer :usage_limit
      t.integer :times_used, null: false, default: 0
      # NULL means it never expires, matching MAS.
      t.datetime :expires_at
      # Revocation is a timestamp rather than a delete, so a spent or leaked
      # token stays visible in the list with its history intact.
      t.datetime :revoked_at
      t.integer :creator_id, null: false
      t.timestamps
    end
    add_index :signup_tokens, :token, unique: true
  end
end
