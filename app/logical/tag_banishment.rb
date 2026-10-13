# frozen_string_literal: true

# The banished-tag set: terms removed from the site's vocabulary outright
# (operator ruling 2026-09-04). Distinct from Danbooru.config.restricted_tags,
# which only withholds names from signed-out viewers: a banished tag is absent
# for EVERYONE but the pipeline -- tag listings, autocomplete, the Modulation
# tag panels -- admins included.
#
# THE LIST IS THE DATABASE (operator ruling 2026-10-12): banished
# TagQuarantine rows, added to by one click (Banish) in the flagged-tag
# review queue, and taken off only by the jail panel's unbanish
# (TagQuarantine#unbanish!; the booru shows no admin a banished name). The old config list (danbooru_local_config.rb banished_tags)
# was moved in by migration 20261012120100 and deleted: one list, not two.
#
# NO REVEAL (operator, relayed 2026-10-12): "the booru itself will never be
# the surface that shows banished tags, ever. The troll jail panel in
# sampling will be used for moderation." The admin reveal_banished toggle is
# gone; no admin is shown a banished post or name.
#
# The blacklist DATA attributes (data-tags) deliberately keep banished names
# so the enforced client-side rules still match -- matching data is not
# display.
#
# POSTS, not only names (operator, 2026-09-24): a post that gains a banished
# tag "is supposed to immediately disappear from the booru view surface". A
# post carrying post_tags is withheld from every viewer but the pipeline,
# through every door a deleted post is withheld by (Post#hidden_as_banished?,
# which hidden_as_deleted? consults, and PostQuery#banished_metatags) --
# deleted or not: a post RELEASED from the jail keeps its banished tag, and a
# jailing whose delete was refused leaves troll_jail on a live post.
module TagBanishment
  def self.list
    TagQuarantine.banished_names.to_a
  end

  def self.banished?(name)
    TagQuarantine.banished_names.include?(name.to_s)
  end

  # The tags that withhold a whole POST: every banished name, and the jail
  # tag, because a jailing whose banished tag was released or never recorded
  # is still a jailing.
  def self.post_tags
    list + [Danbooru.config.troll_jail_tag]
  end

  # Whether posts carrying post_tags are withheld from `user`: from everyone
  # -- signed out, every level, admins -- except the pipeline (pipeline?),
  # which jails, re-syncs and releases these posts and has to be able to
  # find them to do it. Nil is withheld from.
  #
  # Off under test by Danbooru.config.banished_posts_withheld?, the fork
  # restriction pattern; banished_post_visibility_test stubs it on.
  def self.withholds_posts_from?(user)
    return false unless Danbooru.config.banished_posts_withheld?
    return true if user.nil? || !user.respond_to?(:is_anonymous?) || user.is_anonymous?

    !pipeline?(user)
  end

  # Whether `user` is shown banished NAMES: the pipeline alone.
  def self.sees_banished_names?(user) = pipeline?(user)

  # The accounts that act on jailed and banished posts for the site, and so
  # must see them:
  #   - the booru's system user, which Post#jail_on_banished_tags jails as --
  #     it tags and deletes the post it has just been handed;
  #   - the editor accounts (creator_prefixes.yml `editors`: tunnel, sample),
  #     whose jail sync finds a post by md5 to tag and delete it, and which
  #     must find a half-jailed one to finish the delete.
  # An admin is NOT pipeline here, though CreatorPrefixes.editor? says yes to
  # every admin. Nil and signed-out are not.
  # By name, not User.system: this is asked once per post in every listing.
  def self.pipeline?(user)
    return false if user.nil? || !user.respond_to?(:is_anonymous?) || user.is_anonymous?
    return true if user.name == Danbooru.config.system_user
    return false if user.is_admin?

    CreatorPrefixes.editor?(user)
  end

  # The names in `names` this viewer may be shown.
  def self.filter(names, user)
    return names if pipeline?(user)

    banished = TagQuarantine.banished_names
    return names if banished.empty?

    names.reject { |n| banished.include?(n) }
  end
end
