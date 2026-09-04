# frozen_string_literal: true

# A component that displays a user's blacklist rules, and that allows toggling them on and off.
#
# Alongside the user's own rules it renders the ENFORCED rules
# (Danbooru.config.enforced_blacklist): applied to every viewer, stored in no
# account, not disableable, and censored on screen -- reading one takes a
# deliberate click (operator ruling 2026-09-04).
class BlacklistComponent < ApplicationComponent
  attr_reader :user, :inline, :rules

  delegate :link_to_wiki, :chevron_down_icon, :chevron_right_icon, :lock_icon, to: :helpers

  # @param user [User] The user whose blacklist rules to display.
  # @param inline [Boolean] Whether to render the rules on a single line or as a list.
  def initialize(user:, inline: false)
    super
    @user = user
    @inline = inline
    @rules = user.blacklist_rules
  end

  def enforced_rules
    Danbooru.config.enforced_blacklist
  end

  # The admin escape hatch from tag banishment, surfaced only to admins.
  def show_reveal_toggle?
    user.present? && !user.is_anonymous? && user.is_admin?
  end

  def reveal_banished?
    (show_reveal_toggle? && ModulationSetting.find_by(user_id: user.id)&.reveal_banished?) || false
  end
end
