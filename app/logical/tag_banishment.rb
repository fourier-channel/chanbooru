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
# all but an admin with the setting explicitly ON to view it." A post
# carrying post_tags is withheld from every viewer but that admin, through
# every door a deleted post is withheld by (Post#hidden_as_banished?, which
# hidden_as_deleted? consults, and PostQuery#banished_metatags) -- and an
# admin with it ON is not hard-hidden by the enforced blacklist either
# (BlacklistComponent#enforced_rules).
#
# UNTIL 2026-10-12 THIS WITHHELD FROM ADMINS ONLY, and left everyone below
# admin to the deletion that Post#jail_on_banished_tags makes. That held for
# a post the jail had deleted and for no other: a post RELEASED from the jail
# keeps its banished tag, and a jailing whose delete was refused leaves
# troll_jail on a live post (seven such, all one night, when ApproverPruner
# demoted the sampling bot below the level a delete needs). Each of those was
# hidden from the admins and shown to everyone else -- the rule inverted.
# Now the post is withheld from everyone, and the deletion is not the gate.
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

  # Whether posts carrying post_tags are withheld from `user`: from everyone
  # -- signed out, every level, admins -- except
  #   - an admin who has switched reveal_banished on (revealed_to?);
  #   - the pipeline (pipeline?), which jails, re-syncs and releases these
  #     posts and has to be able to find them to do it.
  # Nil is withheld from.
  #
  # Off under test by Danbooru.config.banished_posts_need_reveal?, the fork
  # restriction pattern; banished_post_visibility_test stubs it on.
  def self.withholds_posts_from?(user)
    return false unless Danbooru.config.banished_posts_need_reveal?
    return true if user.nil? || !user.respond_to?(:is_anonymous?) || user.is_anonymous?
    return false if pipeline?(user)

    !revealed_to?(user)
  end

  # The accounts that act on jailed and banished posts for the site, and so
  # must see them:
  #   - the booru's system user, which Post#jail_on_banished_tags jails as --
  #     it tags and deletes the post it has just been handed;
  #   - the editor accounts (creator_prefixes.yml `editors`: tunnel, sample),
  #     whose jail sync finds a post by md5 to tag and delete it, and which
  #     must find a half-jailed one to finish the delete.
  # An admin is NOT pipeline here, though CreatorPrefixes.editor? says yes to
  # every admin: an admin sees these only with reveal on.
  # By name, not User.system: this is asked once per post in every listing.
  def self.pipeline?(user)
    return true if user.name == Danbooru.config.system_user
    return false if user.is_admin?

    CreatorPrefixes.editor?(user)
  end

  # The names in `names` this viewer may be shown.
  def self.filter(names, user)
    return names if list.empty? || revealed_to?(user)

    names.reject { |n| banished?(n) }
  end
end
