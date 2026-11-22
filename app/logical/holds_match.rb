# frozen_string_literal: true

# Which of a search's own holds: values each returned post holds.
#
# A client checking a batch of files before upload asks
# `~holds:<a> ~holds:<b> ...` (Post.holds_matches). A post found through its
# generation record carries posts.md5 -- the stripped bytes -- which is none
# of the hashes asked, so without this the caller cannot tell which file it
# answered and has to split the batch until each hit is alone. This echoes,
# per post, the asked values it holds (operator, 2026-11-22, fourier-basis
# docs/design/PRE_UPLOAD_DUPLICATE_CHECK.md).
#
# It only ever names values the caller sent. It does not publish a post's raw
# md5: that would let anyone test guessed prompts offline against a post's
# image, where holds: costs them a search per guess. Matching follows
# Post.holds_matches exactly; the search already decided which posts the
# viewer may see.
module HoldsMatch
  MD5 = /\A\h{32}\z/
  MXC = %r{\Amxc://}

  # The holds: values a query names, md5s lowercased as holds_matches reads
  # them, in query order, without values holds: never matches.
  #
  # @param post_query [PostQuery]
  # @return [Array<String>]
  def self.values(post_query)
    post_query.select_metatags(:holds).map { |metatag| metatag.value.to_s }
              .map { |value| value.match?(MD5) ? value.downcase : value }
              .select { |value| value.match?(MD5) || value.match?(MXC) }
              .uniq
  end

  # Sets Post#holds on each post to the values it holds, in the order asked.
  # Does nothing when the query names no holds: value, so every other
  # response keeps its shape.
  #
  # @param posts [Enumerable<Post>]
  # @param post_query [PostQuery]
  def self.annotate(posts, post_query)
    values = values(post_query)
    return if values.empty?

    held = held_by(posts, values)
    posts.each { |post| post.holds = values.select { |value| held[post.id].include?(value) } }
  end

  # @return [Hash{Integer => Set<String>}] post id => the values it holds
  def self.held_by(posts, values)
    md5s = values.grep(MD5)
    mxcs = values.grep(MXC)
    held = Hash.new { |hash, key| hash[key] = Set.new }

    # posts.md5 => the asked md5s that answer to it (Post.holds_matches): the
    # md5 itself, the stripped md5 of an upload asked by its raw md5, and the
    # raw md5 of an upload asked by its stripped md5.
    answers = Hash.new { |hash, key| hash[key] = [] }
    md5s.each { |md5| answers[md5] << md5 }
    if md5s.present?
      FourierGenerationMetadata.where(raw_md5: md5s).or(FourierGenerationMetadata.where(md5: md5s)).pluck(:md5, :raw_md5).each do |md5, raw_md5|
        answers[md5] << raw_md5 if raw_md5.in?(md5s)
        answers[raw_md5] << md5 if raw_md5.present? && md5.in?(md5s)
      end
    end
    posts.each { |post| held[post.id].merge(answers[post.md5]) if answers.key?(post.md5) }

    if mxcs.present?
      posts.each { |post| held[post.id] << post.source if post.source.in?(mxcs) }
      PostMxc.where(mxc: mxcs, post_id: posts.map(&:id)).pluck(:post_id, :mxc).each { |post_id, mxc| held[post_id] << mxc }
    end

    held
  end
end
