# frozen_string_literal: true

# Takes private creator tags OUT of the public tag_string, on the posts that
# still carry them there (round-two finding 15). Run by
# script/fourier_remove_private_tags_from_tag_string.rb, DRY-RUN by default;
# it writes only when told to apply.
#
# WHY ANY POST CARRIES ONE. A private creator tag is a FourierTagSource row
# with public: false -- a tag the prompt yielded and only the post's creator
# is shown (FourierCreatorPrivacy). Since fourier-tunnel 37270f5 (2026-08-06)
# such a tag never enters tag_string: the row is the whole of it. For the two
# days before (e5e7e19, 2026-08-04) the tunnel posted creator and auto tags
# together into tag_string, and every surface that reads tag_string --
# /posts/:id.json, tag search, the historical page -- publishes whatever is
# there, to anyone. Those surfaces are Danbooru's own and stay ungated
# (decision 2026-09-29); the fix is to the data. Production held exactly one
# such tag, on one post, when this was written.
#
# WHAT APPLY DOES. For each post whose tag_string carries a tag one of its
# private rows names, removes those tags from tag_string through the ordinary
# post edit -- Post#update with old_tag_string, as PostsController#update
# does it -- as the system user. So the removal is a post version like any
# other edit, and reverting that version puts the tags back. It refuses to
# apply where post versions are not kept (PostVersion.enabled?), because then
# nothing would record what was removed.
#
# The private rows are NOT touched. The tag is still the creator's, and the
# creator still sees it: FourierTagSource.buckets_and_lamps_for draws a
# creator's private rows whether or not their tag is in tag_string.
#
# A tag an implication puts back is reported as kept, not as removed: the edit
# is the ordinary one, and the ordinary edit re-adds an implied tag.
#
# WHAT IT PRINTS. Post ids and counts, never a tag. The tags ARE the private
# data, and a dry run's output gets read, pasted and kept.
module FourierPrivateTagCleanup
  module_function

  # post_id => the private tags its tag_string carries, as found when the plan
  # was made. apply! re-reads each post before it edits it.
  Plan = Struct.new(:posts, :versions_kept, keyword_init: true)

  # Which posts carry which private tags in tag_string. Reads only.
  #
  # @return [Plan]
  def plan
    rows = FourierTagSource.where(public: false)
                           .joins(:post)
                           .where("fourier_tag_sources.tag = ANY(string_to_array(posts.tag_string, ' '))")
                           .order(:post_id, :tag)
                           .pluck(:post_id, :tag)
    posts = rows.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    Plan.new(posts: posts, versions_kept: PostVersion.enabled?)
  end

  # Remove each planned post's private tags from its tag_string, as `user`.
  # One post's failure never stops the rest; each is reported. The tags to
  # remove are re-read per post, from the post as it is now: a plan is a
  # snapshot, and a tag already gone is not removed twice.
  #
  # @return [Hash] { removed: [[post_id, count]], kept: [[post_id, count]],
  #   unchanged: [post_id], failed: [[post_id, message]] }
  def apply!(plan, user: User.system)
    out = { removed: [], kept: [], unchanged: [], failed: [] }
    plan.posts.each_key do |post_id|
      tags = []
      post = Post.find(post_id)
      tags = FourierTagSource.where(post_id: post.id, public: false, tag: post.tag_array).pluck(:tag)
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
      out[:failed] << [post_id, redact("#{e.class}: #{e.message}", tags)]
    end
    out
  end

  # The plan as the dry run prints it: one tab-separated line per post, then a
  # summary. Counts only.
  def report_lines(plan)
    lines = []
    lines << "# post versions: #{plan.versions_kept ? "kept -- each removal is an ordinary, revertible edit" : "NOT KEPT here -- --apply refuses"}"
    lines << "# POST\tpost_id\tprivate_tags_in_tag_string"
    plan.posts.each { |post_id, tags| lines << "POST\t#{post_id}\t#{tags.size}" }
    lines << "# #{plan.posts.size} post(s) carry #{plan.posts.values.sum(&:size)} private creator tag(s) in their public tag_string"
    lines
  end

  # The result as the apply run prints it. Counts and ids only.
  def result_lines(result, user:)
    lines = result[:removed].map { |post_id, count| "REMOVED\t#{post_id}\t#{count}" }
    lines += result[:kept].map { |post_id, count| "KEPT\t#{post_id}\t#{count}\tput back by the ordinary edit (an implication); remove the implying tag or the implication first" }
    lines += result[:unchanged].map { |post_id| "UNCHANGED\t#{post_id}\t0\tno private tag left in its tag_string" }
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
