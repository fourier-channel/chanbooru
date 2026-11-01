# frozen_string_literal: true

# IpDataPruner clears a login's session_id once the login is MAX_AGE old
# (operator, 2026-11-01: IPs and device identifiers live at most 7 days). It is
# the browser's id from its session cookie, the same value user_events.session_id
# holds, so a login left holding it would hand back by one join what the pruner
# cleared from the events. Nothing reads it to sign anyone in -- that is
# login_id -- so a cleared login stays exactly as valid as it was.
class AllowNullLoginSessionSessionId < ActiveRecord::Migration[8.1]
  def change
    change_column_null :login_sessions, :session_id, true
  end
end
