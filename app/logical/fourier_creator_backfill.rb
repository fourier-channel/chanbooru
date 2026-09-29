# frozen_string_literal: true

# Records a creator for tunnel posts made before creators were recorded
# (operator ruling 2026-09-29). Run by script/fourier_backfill_post_creators.rb,
# DRY-RUN by default; it writes only when told to apply.
#
# WHAT IT PROPOSES. For every post uploaded by the tunnel's bot account that
# has no FourierPostCreator yet: when the post carries exactly ONE
# 41chan_<localpart> tag, that tag's MXID (@localpart:<server>) is proposed as
# its creator. Every other post is listed as unresolved and left alone:
#
#   no 41chan_ tag          nothing names a poster
#   N 41chan_ tags          more than one names a poster; which is ambiguous
#   not a poster tag        the one 41chan_ tag is outside what the tunnel mints
#   added after creation    the post's FIRST version did not carry the tag, so
#                           a later edit put it there -- and any member may
#                           edit a post's tags, which is the very spoof the
#                           recorded creator exists to stop
#
# The last check reads the post's first PostVersion when post versions are
# kept (PostVersion.enabled?). When they are not, or a post has no first
# version, the proposal stands on the current tags alone and says so in its
# `at_creation` column (unknown) -- the ruling's criterion is the current tag,
# and the column is there so the run's reader can see how much rests on it.
#
# Nothing is ever overwritten: FourierPostCreator.record! keeps a creator that
# is already on record, and a post that has one is not scanned at all.
module FourierCreatorBackfill
  module_function

  Proposal = Struct.new(:post_id, :tag, :mxid, :at_creation, keyword_init: true)
  Unresolved = Struct.new(:post_id, :reason, :tags, keyword_init: true)
  Plan = Struct.new(:uploader, :scanned, :proposals, :unresolved, :versions_checked, keyword_init: true)

  BATCH = 1_000

  # Which posts would get which creator. Reads only.
  #
  # @param uploader [User] the tunnel's bot account
  # @return [Plan]
  def plan(uploader:)
    proposals = []
    unresolved = []
    scanned = 0
    versions_checked = PostVersion.enabled?

    Post.where(uploader_id: uploader.id)
        .where.not(id: FourierPostCreator.select(:post_id))
        .in_batches(of: BATCH) do |batch|
      rows = batch.pluck(:id, :tag_string)
      scanned += rows.size
      first_tags = versions_checked ? first_version_tags(rows.map(&:first)) : {}

      rows.each do |post_id, tag_string|
        candidates = tag_string.to_s.split.select { |tag| tag.start_with?(CreatorActivity::TUNNEL_PREFIX) }
        if candidates.size != 1
          reason = candidates.empty? ? "no 41chan_ tag" : "#{candidates.size} 41chan_ tags"
          unresolved << Unresolved.new(post_id: post_id, reason: reason, tags: candidates)
          next
        end

        tag = candidates.first
        mxid = FourierCreatorPrivacy.mxid_for_poster_tag(tag)
        if mxid.nil?
          unresolved << Unresolved.new(post_id: post_id, reason: "not a poster tag", tags: candidates)
          next
        end

        at_creation = first_tags.key?(post_id) ? first_tags[post_id].include?(tag) : nil
        if at_creation == false
          unresolved << Unresolved.new(post_id: post_id, reason: "added after creation", tags: candidates)
          next
        end

        proposals << Proposal.new(post_id: post_id, tag: tag, mxid: mxid, at_creation: at_creation)
      end
    end

    Plan.new(uploader: uploader, scanned: scanned, proposals: proposals, unresolved: unresolved, versions_checked: versions_checked)
  end

  # Record every proposal. One post's failure never stops the rest; each is
  # reported. A post that gained a creator since the plan was made keeps it.
  #
  # @return [Hash] { recorded:, kept:, failed: [[post_id, message], ...] }
  def apply!(plan, recorded_by:)
    out = { recorded: 0, kept: 0, failed: [] }
    plan.proposals.each do |proposal|
      post = Post.find(proposal.post_id)
      row = FourierPostCreator.record!(post, proposal.mxid, recorded_by)
      if FourierPostCreator.same_mxid?(row.mxid, proposal.mxid) && row.recorded_by == recorded_by.id
        out[:recorded] += 1
      else
        out[:kept] += 1
      end
    rescue StandardError => e
      out[:failed] << [proposal.post_id, "#{e.class}: #{e.message}"]
    end
    out
  end

  # The plan as the dry run prints it: one tab-separated line per post, then a
  # summary. Columns are fixed so the output can be sorted, grepped or diffed.
  def report_lines(plan)
    lines = []
    lines << "# uploader #{plan.uploader.name} (##{plan.uploader.id}); first-version check: #{plan.versions_checked ? "on" : "UNAVAILABLE -- post versions are not kept here, every at_creation is unknown"}"
    lines << "# PROPOSE\tpost_id\ttag\tmxid\tat_creation"
    plan.proposals.each do |p|
      at = p.at_creation.nil? ? "unknown" : "yes"
      lines << "PROPOSE\t#{p.post_id}\t#{p.tag}\t#{p.mxid}\t#{at}"
    end
    lines << "# UNRESOLVED\tpost_id\treason\t41chan_ tags"
    plan.unresolved.each do |u|
      lines << "UNRESOLVED\t#{u.post_id}\t#{u.reason}\t#{u.tags.join(",")}"
    end
    unknown = plan.proposals.count { |p| p.at_creation.nil? }
    lines << "# scanned #{plan.scanned} post(s) with no recorded creator: #{plan.proposals.size} proposed " \
             "(#{unknown} with at_creation unknown), #{plan.unresolved.size} unresolved"
    lines
  end

  # The configured posting bot names that match no booru account. A bot is
  # known by NAME (FourierCreatorPrivacy.posting_bot?), so a renamed one drops
  # off the list silently and its account reads as a person -- the creator of
  # every post it uploaded with no recorded creator. The script warns about
  # each one before it does anything else.
  def unmatched_bot_names
    FourierCreatorPrivacy.posting_bot_names.reject { |name| User.find_by_name(name) }
  end

  # post_id => the tags of that post's first version, for the posts that have
  # one on record.
  def first_version_tags(post_ids)
    PostVersion.where(post_id: post_ids, version: 1).pluck(:post_id, :tags)
               .to_h { |post_id, tags| [post_id, tags.to_s.split.to_set] }
  end
end
