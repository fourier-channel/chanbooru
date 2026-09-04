# frozen_string_literal: true

class AddSessionBarToModulationSettings < ActiveRecord::Migration[8.1]
  def change
    # The Manage Session bar is part of the header and its open state is part
    # of the user's constant environment -- it stays where it was left.
    # session_autorefresh is the "force a refresh on auth change" toggle,
    # default on by operator request: the page must show what the current
    # account can see, immediately.
    add_column :modulation_settings, :session_bar_open, :boolean, null: false, default: false
    add_column :modulation_settings, :session_autorefresh, :boolean, null: false, default: true
  end
end
