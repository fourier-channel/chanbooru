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

  # The conjunction rules from the config: hard-hiding for every viewer.
  #
  # NOT the banished names (operator, relayed 2026-10-12: "the booru itself
  # will never be the surface that shows banished tags, ever"). This box is
  # sent to every viewer of every page, and a rule in it is one click from
  # being read. Nothing is lost by leaving them out: a post carrying a
  # banished name is withheld server-side from everyone the box is drawn
  # for (TagBanishment.withholds_posts_from?), so no rule here could match.
  def enforced_rules
    Danbooru.config.enforced_blacklist
  end
end
