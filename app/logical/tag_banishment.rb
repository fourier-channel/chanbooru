# frozen_string_literal: true

# The banished-tag set: terms removed from the site's vocabulary outright
# (operator ruling 2026-09-04). Distinct from Danbooru.config.restricted_tags,
# which only withholds names from signed-out viewers: a banished tag is absent
# for EVERYONE -- tag listings, autocomplete, the Modulation tag panels --
# admins included, unless an admin has deliberately switched reveal_banished
# on in their modulation settings. The operator's own words: "they should be
# hidden to me without a specific toggle on, and apparently missing/deleted
# from the server altogether for everyone else."
#
# Post visibility needs no second gate here: fourier-sampling auto-jails the
# material, so these tags only exist on deleted posts. The blacklist DATA
# attributes (data-tags) deliberately keep banished names so the enforced
# client-side rules still match for the staff who can see deleted posts --
# matching data is not display.
module TagBanishment
  def self.list
    Danbooru.config.banished_tags
  end

  def self.banished?(name)
    list.include?(name.to_s)
  end

  def self.revealed_to?(user)
    return false unless user.respond_to?(:is_admin?) && user.is_admin?

    ModulationSetting.find_by(user_id: user.id)&.reveal_banished? || false
  end

  # The names in `names` this viewer may be shown.
  def self.filter(names, user)
    return names if list.empty? || revealed_to?(user)

    names.reject { |n| banished?(n) }
  end
end
