# frozen_string_literal: true

# Every Matrix account gets a booru account of the same name (operator,
# 2026-11-07): the first booru request carrying a verified Matrix identity
# creates and signs in the account, so a newcomer arriving through Technetium
# has a booru session before the first picture is asked for. The link is held
# here, one Matrix ID per account and one account per Matrix ID, stored
# lowercased (MatrixAccount).
#
# Accounts that already exist keep themselves. Each is linked where the creator
# galleries already prove the pair beyond doubt: a gallery names both, the
# account owns no gallery under another Matrix ID, and no other account owns
# one under this one. Anything less is left for the account's owner to link by
# signing in with its password (MatrixAccount#link_signed_in). A deleted
# account is never linked, as a deletion unlinks one (UserDeletion).
class AddMatrixIdToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :matrix_id, :string
    add_index :users, :matrix_id, unique: true, where: "matrix_id IS NOT NULL"
    execute <<~SQL.squish
      UPDATE users SET matrix_id = pairs.matrix_id
      FROM (
        SELECT MIN(lower(matrix_id)) AS matrix_id, user_id FROM creator_galleries
        WHERE user_id IS NOT NULL GROUP BY user_id HAVING COUNT(DISTINCT lower(matrix_id)) = 1
      ) AS pairs
      WHERE users.id = pairs.user_id AND NOT users.is_deleted
        AND NOT EXISTS (
          SELECT 1 FROM creator_galleries other
          WHERE lower(other.matrix_id) = pairs.matrix_id AND other.user_id IS NOT NULL AND other.user_id <> pairs.user_id
        )
    SQL
  end

  def down
    remove_column :users, :matrix_id
  end
end
