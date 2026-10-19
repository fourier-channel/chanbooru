# frozen_string_literal: true

# Takes private creator tags OUT of the public tag_string, on the posts that
# still carry them there (round-two finding 15). Run by
# script/fourier_remove_private_tags_from_tag_string.rb, DRY-RUN by default;
# it writes only when told to apply.
#
# WHY ANY POST CARRIES ONE. A private creator tag is a FourierTagSource row
# with public: false -- a tag the prompt yielded and only the post's creator
# is shown (FourierCreatorPrivacy). Since fourier-tunnel 37270f5 (2026-08-06)
# a tag only the prompt yielded stays out of tag_string: the row is the whole
# of it. A PUBLIC_LABELS name is the exception: the tunnel publishes it on
# purpose (publicTagsFor) and Post#add_automatic_tags adds "ai-generated"
# from the file; where the prompt names one too, the tunnel's private row
# for it sits beside a public tag put there on purpose, which is not a leak.
# For the two days before (e5e7e19, 2026-08-04) the tunnel posted creator
# and auto tags together into tag_string, and every surface that reads
# tag_string -- /posts/:id.json, tag search, the historical page -- publishes
# whatever is there, to anyone. Those surfaces are Danbooru's own and stay
# ungated (decision 2026-09-29); the fix is to the data.
#
# WHICH OCCURRENCES ARE LEAKS. Only the posting bot's: a tag one of the
# post's private rows names, in its tag_string because a posting bot put it
# there (FourierPrivateTagLineage, BUR review 2026-10-19). A tag a person, a
# bulk update request or an implication put on the public list is that edit's
# own choice and shows to everyone (operator ruling 2026-10-19: a public-list
# tag shows to everyone even when the creator's private row names it), so it
# is never listed; nor is a label the bot publishes on purpose
# (FourierPrivateTagLineage::PUBLIC_LABELS), nor an occurrence whose add the
# post's versions cannot show -- those are counted apart, never removed blind.
# Where post versions are not kept, who added a tag cannot be read at all, so
# nothing is planned.
#
# WHAT APPLY DOES. For each planned post, removes the bot-leaked tags from
# tag_string through the ordinary post edit -- Post#update with
# old_tag_string, as PostsController#update does it -- as the system user.
# So the removal is a post version like any other edit, which the post's
# creator may revert or undo; anyone else's revert or undo is refused, since
# it would publish the creator's prompt again
# (FourierPrivateTagLineage.refuse_restore!, 2026-10-19). It refuses to apply
# where post versions are not kept (PostVersion.enabled?), because then
# nothing would record what was removed.
#
# The private rows are NOT touched. The tag is still the creator's, and the
# creator still sees it: FourierTagSource.buckets_and_lamps_for draws a
# creator's private rows whether or not their tag is in tag_string.
#
# A tag the ordinary edit puts back is reported as kept, not as removed: the
# ordinary edit re-adds what another tag implies, and what the booru derives
# itself (Post#add_automatic_tags from the file, Tag.automatic_tags_for from
# another tag's name).
#
# WHAT IT PRINTS. Post ids and counts, never a tag. The tags ARE the private
# data, and a dry run's output gets read, pasted and kept.
module FourierPrivateTagCleanup
  module_function

  # posts: post_id => the bot-leaked private tags its tag_string carries, as
  # found when the plan was made; apply! re-reads each post before it edits
  # it. skipped: how many (post, private tag in tag_string) pairs were not
  # planned, by why -- :public (a person's, a bulk update's or an
  # implication's add), :label (PUBLIC_LABELS) and :unknown (no add the
  # versions show).
  Plan = Struct.new(:posts, :versions_kept, :skipped, keyword_init: true)

  # Which posts carry which bot-leaked private tags in tag_string. Reads only.
  #
  # @return [Plan]
  def plan
    found = occurrences(FourierTagSource.all)
    kinds = found.values.flat_map(&:values).tally
    posts = found.transform_values { |tags| tags.select { |_, kind| kind == FourierPrivateTagLineage::BOT }.keys }.reject { |_, tags| tags.empty? }
    Plan.new(posts: posts, versions_kept: PostVersion.enabled?, skipped: %i[public label unknown].index_with { |kind| kinds[kind].to_i })
  end

  # post_id => { tag => :bot | :public | :label | :unknown } for every private
  # creator tag (among `rows`) whose post's tag_string carries it now: the
  # lineage of that occurrence (FourierPrivateTagLineage.current), :label for
  # a name the posting bot publishes on purpose, and :unknown for all of them
  # where post versions are not kept.
  def occurrences(rows)
    found = rows.where(public: false)
                .joins(:post)
                .where("fourier_tag_sources.tag = ANY(string_to_array(posts.tag_string, ' '))")
                .order(:post_id, :tag)
                .pluck(:post_id, :tag)
                .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    lineage = PostVersion.enabled? ? FourierPrivateTagLineage.current(Post.where(id: found.keys).to_a) : {}
    found.to_h do |post_id, tags|
      [post_id, tags.index_with { |tag| FourierPrivateTagLineage::PUBLIC_LABELS.include?(tag) ? :label : lineage.dig(post_id, tag) || FourierPrivateTagLineage::UNKNOWN }]
    end
  end

  # Remove each planned post's bot-leaked private tags from its tag_string,
  # as `user`. One post's failure never stops the rest; each is reported. The
  # tags to remove are re-read per post, from the post and its versions as
  # they are now: a plan is a snapshot, a tag already gone is not removed
  # twice, and one a person has typed since is theirs.
  #
  # @return [Hash] { removed: [[post_id, count]], kept: [[post_id, count]],
  #   unchanged: [post_id], failed: [[post_id, message]] }
  def apply!(plan, user: User.system)
    out = { removed: [], kept: [], unchanged: [], failed: [] }
    plan.posts.each_key do |post_id|
      found = {}
      post = Post.find(post_id)
      found = occurrences(FourierTagSource.where(post_id: post.id)).fetch(post.id, {})
      tags = found.select { |_, kind| kind == FourierPrivateTagLineage::BOT }.keys
      if tags.empty?
        out[:unchanged] << post_id
        next
      end

      CurrentUser.scoped(user) do
        post.update!(old_tag_string: post.tag_string, tag_string: (post.tag_array - tags).join(" "))
      end
      still = post.reload.tag_array & tags
      out[:removed] << [post_id, tags.size - still.size] if still.size < tags.size
      out[:kept] << [post_id, still.size] if still.any?
    rescue StandardError => e
      out[:failed] << [post_id, redact("#{e.class}: #{e.message}", found.keys | plan.posts[post_id].to_a)]
    end
    out
  end

  # The plan as the dry run prints it: one tab-separated line per post, then a
  # summary. Counts only.
  def report_lines(plan)
    if plan.versions_kept
      versions = "kept -- each removal is an ordinary, revertible edit"
    else
      versions = "NOT KEPT here -- who added each tag cannot be read, so nothing is planned and --apply refuses; configure the post archive (aws_sqs_archives_url)"
    end
    lines = ["# post versions: #{versions}"]
    lines << "# POST\tpost_id\tbot_leaked_private_tags_in_tag_string"
    plan.posts.each { |post_id, tags| lines << "POST\t#{post_id}\t#{tags.size}" }
    lines << "# #{plan.skipped[:public]} pair(s) skipped: put on the public list by a person, a bulk update or an implication -- that edit's own choice, not a leak"
    lines << "# #{plan.skipped[:label]} pair(s) skipped: a label the posting bot publishes on purpose, not a leak"
    lines << "# #{plan.skipped[:unknown]} pair(s) skipped: who added them cannot be read from the post's versions; nothing is removed blind"
    lines << "# #{plan.posts.size} post(s) carry #{plan.posts.values.sum(&:size)} private creator tag(s) the posting bot leaked into their public tag_string"
    lines
  end

  # The result as the apply run prints it. Counts and ids only.
  def result_lines(result, user:)
    lines = result[:removed].map { |post_id, count| "REMOVED\t#{post_id}\t#{count}" }
    lines += result[:kept].map do |post_id, count|
      "KEPT\t#{post_id}\t#{count}\tput back by the ordinary edit, which re-adds what another tag implies and what the booru " \
        "derives from the file or from another tag's name; to remove it, remove that implication or tag first"
    end
    lines += result[:unchanged].map { |post_id| "UNCHANGED\t#{post_id}\t0\tno private tag the posting bot leaked is left in its tag_string" }
    lines += result[:failed].map { |post_id, message| "FAILED\t#{post_id}\t#{message}" }
    lines << "# APPLIED as #{user.name}: #{result[:removed].size} post(s) edited, #{result[:kept].size} kept a tag, " \
             "#{result[:unchanged].size} unchanged, #{result[:failed].size} failed"
    lines
  end

  # An exception message with every private tag it might name taken out, so a
  # failure line can say what went wrong without saying what the tag was.
  def redact(message, tags)
    tags.sort_by { |tag| -tag.length }.reduce(message.to_s) { |text, tag| text.gsub(tag, "[private tag]") }
  end
end
