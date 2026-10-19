# frozen_string_literal: true

# A bulk update request's reason, kept on the request. Upstream wrote it only
# into the forum post every request opened; while the forum is retired a
# request opens none (BulkUpdateRequest.forum_retired?), and the reason --
# who asked and why -- would otherwise be lost. Nullable, no default: a
# request filed before this column has its reason in its forum post. No
# backfill: production had no requests.
class AddReasonToBulkUpdateRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :bulk_update_requests, :reason, :text
  end
end
