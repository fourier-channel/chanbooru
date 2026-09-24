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
# The blacklist DATA attributes (data-tags) deliberately keep banished names
# so the enforced client-side rules still match -- matching data is not
# display.
#
# POSTS, not only names (operator, 2026-09-24): a post that gains a banished
# tag "is supposed to immediately disappear from the booru view surface for
# all but an admin with the setting explicitly ON to view it." Post's
# jail_on_banished_tags deletes it, which already withholds it from everyone
# below admin. What this adds is the admin half: a post carrying post_tags
# is withheld from an admin whose reveal is off, through every door a
# deleted post is withheld by (Post#hidden_as_banished?, which
# hidden_as_deleted? consults, and PostQuery#banished_metatags) -- and an
# admin with it ON is not hard-hidden by the enforced blacklist either
# (BlacklistComponent#enforced_rules).
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

  # The tags that withhold a whole POST from an admin whose reveal is off:
  # every banished name, and the jail tag, because a jailing whose banished
  # tag was released or never recorded is still a jailing.
  def self.post_tags
    list + [Danbooru.config.troll_jail_tag]
  end

  # Whether posts carrying post_tags are withheld from `user`. Admins only:
  # everyone below admin already gets a 404 for the deleted post a jailing
  # leaves, and that rule is theirs, not this one's. Nil is nobody's admin.
  #
  # Off under test by Danbooru.config.banished_posts_need_reveal?, the fork
  # restriction pattern; banished_post_visibility_test stubs it on.
  def self.withholds_posts_from?(user)
    return false unless Danbooru.config.banished_posts_need_reveal?
    return false unless user.respond_to?(:is_admin?) && user.is_admin?

    !revealed_to?(user)
  end

  # The names in `names` this viewer may be shown.
  def self.filter(names, user)
    return names if list.empty? || revealed_to?(user)

    names.reject { |n| banished?(n) }
  end
end
