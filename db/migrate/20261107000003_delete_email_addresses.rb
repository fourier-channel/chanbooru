# frozen_string_literal: true

# 41chan keeps no email addresses (operator, 2026-11-07): signup no longer asks
# for one and the emails section is retired, so the addresses already stored
# are deleted. On production that was 11, none verified; no other table held a
# copy (no email-change mod action, no mailer job naming one). TRUNCATE, not
# DELETE: it drops the table's files and its indexes' (two trigram indexes
# hold the address text) instead of leaving the rows dead on disk until a
# vacuum. The nightly backups age out the last copies within their 30 days.
class DeleteEmailAddresses < ActiveRecord::Migration[8.1]
  def up
    execute "TRUNCATE email_addresses"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "deleted email addresses are gone on purpose"
  end
end
