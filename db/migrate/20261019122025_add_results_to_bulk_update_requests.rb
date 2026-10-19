# frozen_string_literal: true

# The record of a bulk update request's run, one entry a script line: what
# the line did, the posts it skipped and why, and the line a run stopped at
# (BulkUpdateRequest::Processor#process!). Upstream kept only a status, so a
# run that skipped posts or failed halfway read the same as one that did
# everything. Never served raw: it holds the id of every skipped post,
# hidden ones included, and BulkUpdateRequestPolicy#api_attributes serves it
# filtered per viewer instead. No backfill: production had no requests.
class AddResultsToBulkUpdateRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :bulk_update_requests, :results, :jsonb, default: [], null: false
  end
end
