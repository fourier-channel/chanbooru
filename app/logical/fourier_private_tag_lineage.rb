# frozen_string_literal: true

# WHO PUT A TAG ON A POST'S PUBLIC LIST, per occurrence (BUR review
# 2026-10-19). THE ONE PLACE this is decided: the private-tag cleanup's plan
# (FourierPrivateTagCleanup) and the revert/undo refusal (refuse_restore!)
# ask here, and anything else that must tell a leak from a choice asks here
# too rather than deciding it again.
#
# Why it is needed. A private creator tag (a FourierTagSource row with
# public: false, the creator's prompt -- FourierCreatorPrivacy) sometimes
# also sits in tag_string: the posting bot put it there (2026-08-04..06, and
# a name the tunnel both labels publicly and finds in a prompt), or a person
# typed it. The bot's add is a LEAK of the creator's prompt; a person's add is
# that person's own choice, which the operator ruled shows to everyone
# (2026-10-19: "a public-list tag shows to everyone even when a creator's
# private prompt row names it"). Who touched the post last says neither: a
# member's undo of the cleanup re-adds a leaked tag under the member's name,
# and the bot's own deliberate public label reads like a leak. So each
# occurrence is judged by its LINEAGE, walked from the post's versions in
# order:
#
#   - an add by a posting bot (FourierCreatorPrivacy.posting_bot_names)
#     starts a BOT lineage;
#   - an add by any other account starts a PUBLIC one;
#   - an add whose version names no account starts an UNKNOWN one: no
#     adder is on record (post_versions.updater_id is nullable -- a post
#     saved outside a request and outside CurrentUser.scoped);
#   - a PUBLIC_LABELS name starts a PUBLIC one whoever added it, unless a
#     move brought it (below): the bot publishes it on purpose whatever the
#     prompt says, and a person's add is theirs, so no such add of it is a
#     leak of the prompt;
#   - an add by the system account that MOVES a tag (TagMover: the old name
#     leaves in the same version and the new one arrives) inherits the old
#     name's lineage, as move_tag! carries its private row. A move is an
#     alias (any status), a bulk update request's rename (no alias row), or
#     the *_(cosplay) / *_(style) tag TagMover moves along with either (no
#     row of its own);
#   - a removal ends the lineage; a later add starts a new one.
#
# A tag in a history that does not begin at the post's first version has no
# known add either: UNKNOWN (a PUBLIC_LABELS name aside), which a caller
# treats as it would BOT where publishing is at stake. So is a tag the post
# carries that its newest version does not hold yet, and every tag of a post
# with no versions at all (current).
#
# Adds and removals are read from consecutive SNAPSHOTS (PostVersion#tags),
# not from added_tags/removed_tags: the archive merges an account's edits
# within an hour into one version and rewrites its snapshot, and the
# snapshot is the version's content.
#
# What it cannot tell (stated, not hidden): a person's revert or undo that
# re-added a leaked tag BEFORE 2026-10-19 reads as that person's add, since a
# version does not say how it was made. refuse_restore! stops new ones. And
# an account that removes a tag and puts it back within the hour leaves one
# merged version with neither change in it, so the tag keeps the lineage it
# had.
module FourierPrivateTagLineage
  BOT = :bot
  PUBLIC = :public
  UNKNOWN = :unknown

  # Names a posting bot puts on the public list ON PURPOSE, whatever the
  # prompt it read says. An occurrence of one is never a leak of the prompt,
  # even where the creator's private row names it too. From fourier-tunnel
  # image-plan.js publicTagsFor: AI_GENERATED_TAG ("ai-generated", when the
  # strip took a generator's own signal) and NO_TRAIN_TAG ("no_train", every
  # Discord post -- the tag fourier-sampling's poster puts on archive-sourced
  # posts, LandingCategory::ARCHIVE_TAG). A label the tunnel adds there is
  # added here, or its collisions with prompts read as leaks.
  PUBLIC_LABELS = ["ai-generated", LandingCategory::ARCHIVE_TAG].freeze

  # Raised by Post#revert_to and PostVersion#undo! (refuse_restore!) instead
  # of publishing a creator's private tag again; ApplicationController
  # answers 422 with the message. It names no tag: the names are the
  # creator's.
  class RestoreRefused < StandardError
    def initialize(count)
      super("This version would put back #{count} tag(s) only the post's creator may publish; add any tag you mean by hand.")
    end
  end

  module_function

  # name => BOT | PUBLIC | UNKNOWN for every tag `version`'s snapshot holds,
  # walked from the post's versions up to and including it.
  #
  # @param version [PostVersion]
  # @return [Hash{String => Symbol}]
  def after(version)
    versions = PostVersion.where(post_id: version.post_id).where(version: ..version.version).order(:version, :id).to_a
    walk(versions).last&.last || {}
  end

  # [[version, { name => lineage }], ...] for `versions` (one post's), oldest
  # first, each with the lineage of every tag its snapshot holds.
  #
  # @param versions [Array<PostVersion>]
  # @return [Array<Array(PostVersion, Hash{String => Symbol})>]
  def walk(versions)
    versions = versions.sort_by { |version| [version.version.to_i, version.id] }
    return [] if versions.empty?

    names = User.where(id: versions.map(&:updater_id).uniq).pluck(:id, :name).to_h
    bots = FourierCreatorPrivacy.posting_bot_names
    move_pairs = moves(versions)

    state = {}
    previous = nil
    versions.map do |version|
      tags = version.tag_array
      before = previous ? previous.tag_array : []
      added = tags - before
      removed = before - tags
      updater = names[version.updater_id].to_s
      # No known adder: a history that does not begin at the first version,
      # or a version that names no account (updater_id is nullable).
      if (previous.nil? && version.version.to_i > 1) || !names.key?(version.updater_id)
        origin = UNKNOWN
      elsif bots.any? { |bot| bot.casecmp?(updater) }
        origin = BOT
      else
        origin = PUBLIC
      end
      # new name => the old names it moved from. Two moved onto one (two
      # aliases with one consequent, in one version) take the lineage
      # nearest a leak: BOT, then UNKNOWN, then PUBLIC.
      moved = (updater == Danbooru.config.system_user) ? move_pairs.select { |from, to| removed.include?(from) && added.include?(to) }.group_by(&:last).transform_values { |pairs| pairs.map(&:first) } : {}
      lineage = lambda do |name|
        if moved.key?(name)
          moved[name].map { |from| state.fetch(from, UNKNOWN) }.min_by { |kind| [BOT, UNKNOWN, PUBLIC].index(kind) }
        elsif PUBLIC_LABELS.include?(name)
          PUBLIC
        else
          origin
        end
      end

      state = state.except(*removed).merge(added.index_with(&lineage))
      previous = version
      [version, state]
    end
  end

  # [old name, new name] for every move between a name some version dropped
  # and a name it gained: an alias (any status: an alias removed later still
  # moved the posts when it was made); a rename filed in a bulk update
  # request that ran (BulkUpdateRequest::Command::Rename runs TagMover with
  # no alias row); and for either, the *_(cosplay) and *_(style) tags
  # TagMover moves along with it (move_cosplay_tag!, move_style_tag!), which
  # leave no row of their own.
  def moves(versions)
    pairs = versions.each_cons(2).map { |a, b| [a.tag_array - b.tag_array, b.tag_array - a.tag_array] }
    removed = pairs.flat_map(&:first).uniq
    added = pairs.flat_map(&:last).uniq
    return [] if removed.empty? || added.empty?

    olds = (removed + removed.map { |name| name.delete_suffix("_(cosplay)").delete_suffix("_(style)") }).uniq
    aliases = TagAlias.where(antecedent_name: olds).distinct.pluck(:antecedent_name, :consequent_name)
    renames = BulkUpdateRequest.where.not(status: %w[pending rejected]).where_array_includes_any(:tags, olds).flat_map do |request|
      request.processor.commands.grep(BulkUpdateRequest::Command::Rename).map(&:affected_tags)
    end
    (aliases + renames).flat_map { |from, to| [[from, to], ["#{from}_(cosplay)", "#{to}_(cosplay)"], ["#{from}_(style)", "#{to}_(style)"]] }
                       .select { |from, to| removed.include?(from) && added.include?(to) }.uniq
  end

  # post_id => { name => BOT | PUBLIC | UNKNOWN } for every tag each post's
  # tag_string holds NOW, walked from all of its versions. A tag the newest
  # version does not hold yet (the archive is behind the post), and every
  # tag of a post with no versions, is UNKNOWN.
  #
  # @param posts [Array<Post>]
  # @return [Hash{Integer => Hash{String => Symbol}}]
  def current(posts)
    versions = PostVersion.where(post_id: posts.map(&:id)).order(:post_id, :version, :id).group_by(&:post_id)
    posts.to_h do |post|
      state = walk(versions.fetch(post.id, [])).last&.last || {}
      [post.id, post.tag_array.index_with { |name| state.fetch(name, UNKNOWN) }]
    end
  end

  # Refuse to put `names` back onto `post` from `source` -- the version whose
  # snapshot holds them (a revert's target; for an undo, the version before
  # the undone one) -- where that would publish a creator's private tag
  # (a private row on the post, under the name the tag lands as once
  # aliases apply) whose occurrence there is not a person's (BOT or UNKNOWN
  # lineage). The post's creator may (FourierCreatorPrivacy.visible_to?);
  # nobody else, admins and moderators included. Typing the tag by hand is
  # a person's own add and is not asked here.
  #
  # @raise [RestoreRefused]
  def refuse_restore!(post, names, source:, user: CurrentUser.user, request: CurrentUser.request)
    carried = post.tag_string.to_s.split
    names = Array(names).map(&:to_s).uniq
    landing = names.zip(TagAlias.to_aliased(names)).to_h.reject { |_, name| carried.include?(name) }
    return if landing.empty?

    private_names = FourierTagSource.where(post_id: post.id, public: false, tag: landing.values.uniq).pluck(:tag)
    restoring = landing.select { |_, name| private_names.include?(name) }
    return if restoring.empty?
    return if FourierCreatorPrivacy.visible_to?(post, user, request)

    lineage = source ? after(source) : {}
    refused = restoring.reject { |from, _| lineage[from] == PUBLIC }.values.uniq
    raise RestoreRefused, refused.size if refused.any?
  end
end
