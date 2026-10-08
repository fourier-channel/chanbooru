# frozen_string_literal: true

# WHO CONTROLS A POST -- the single answer, and the only place it is written
# (design CREATOR_VISIBILITY sections 3 and 9, ruled 2026-10-07). "Control" is
# what a creator's visibility panel will act on: the controller decides who
# sees the post. Enforcement (query, page, media) reads this module and adds
# nothing of its own.
#
# A post's controllers are CREATOR GALLERIES -- the only stored link from a
# Matrix identity to a booru account (creator_galleries.user_id, set from a
# verified match). In order:
#
#   1. The RECORDED creator (fourier_post_creators, filed by the posting bot
#      from the authenticated Matrix sender): the gallery with that matrix_id,
#      matched case-insensitively. When a creator is recorded it is the ONLY
#      controller, gallery or no gallery -- "one controller per post" -- so no
#      claim on a tag the post also carries can take a Matrix post from the
#      person who posted it.
#   2. Otherwise, from the post's LOCKED creator tags (CreatorPrefixes):
#      - a tag under the MASTER prefix (provenance Matrix, today 41chan_)
#        gives control to @<localpart>:<this homeserver>'s gallery with no
#        claim at all (Q6: "41chan_<self> needs no claim");
#      - any other locked tag gives control to the gallery holding an
#        APPROVED claim on that tag name (ArtistClaim.tag_name).
#      Several tags can name several galleries; all of them are returned, and
#      "narrowest wins" between them is enforcement's to apply.
#
# RE-CHECKED AT USE, never trusted from the row: a claim confers control only
# while its tag is locked by the live list AND it still satisfies the
# stripped-name rule against that list (ArtistClaim.standing, which every
# reader of a claim asks). An unlocked tag is one any member can add to any
# post.
#
# SAFE ONLY WHILE THE LOCK HOLDS (section 3). Control by tag -- a claim, or a
# master tag with no claim -- trusts that nobody but an admin or the posting
# service moves a locked tag (Post#validate_creator_prefixed_tags). Approved
# aliases, renames and implications retag posts as the system user, which the
# lock lets through, so a bulk update request touching a locked tag is
# approved by an admin alone (BulkUpdateRequest::Command::CreateAlias and
# CreateImplication#approval_level); upstream let a builder approve one
# between small artist tags, which creator tags are.
#
# NEVER TagGrant. A moderator issues TagGrants -- to anyone, themselves
# included -- and moderators see nothing a creator hid (Q2). ArtistClaim.owner?
# reads TagGrant for artist EDITING and is deliberately not called here.
#
# NEVER the request. Enforcement runs where there is no request (query-level
# exclusion, API calls, fourier-auth's per-md5 ask carries only the booru
# session), so control is read from stored rows only, keyed on the booru User.
#
# The prefix list is read through CreatorPrefixes.visibility_config, which
# keeps the last good list when the live file breaks and says so in the log:
# visibility must not switch off because a file broke, and the lock itself
# refuses tag edits meanwhile, so the tags it judges cannot have moved.
#
# Two shapes, which must always agree (creator_control_test asks every case of
# both): per post (`controller_gallery_ids`, `controls?`) and per user
# (`controlled_post_ids`, through `gallery_post_ids`), each in a fixed number
# of queries -- no N+1.
module CreatorControl
  module_function

  # The galleries controlling each post, in a fixed number of queries.
  #
  # @param posts [Enumerable<Post>] each needs id and tag_string
  # @return [Hash{Integer => Array<Integer>}] post id => sorted gallery ids,
  #   with every given post present (an empty list when nobody controls it)
  def controller_gallery_ids(posts)
    posts = Array(posts).select(&:id)
    return {} if posts.empty?

    recorded = FourierPostCreator.where(post_id: posts.map(&:id)).pluck(:post_id, :mxid).to_h
    entries = prefix_entries
    tags_of = posts.to_h { |post| [post.id, recorded.key?(post.id) ? [] : locked_tags(post.tag_string, entries)] }
    all_tags = tags_of.values.flatten.uniq

    master_mxids = all_tags.filter_map { |tag| master_mxid(tag, entries) }
    galleries = galleries_by_mxid(recorded.values + master_mxids)
    claims = claimant_gallery_ids(all_tags, entries)

    posts.to_h do |post|
      if recorded.key?(post.id)
        ids = [galleries[recorded[post.id].downcase]]
      else
        ids = tags_of[post.id].flat_map { |tag| [galleries[master_mxid(tag, entries)&.downcase], *claims[tag]] }
      end
      [post.id, ids.compact.uniq.sort]
    end
  end

  # The booru accounts controlling each post: controller_gallery_ids through
  # creator_galleries.user_id. A gallery not yet linked to an account
  # contributes nobody.
  #
  # @return [Hash{Integer => Array<Integer>}] post id => sorted user ids
  def controller_user_ids(posts)
    by_post = controller_gallery_ids(posts)
    users = CreatorGallery.where(id: by_post.values.flatten.uniq).where.not(user_id: nil).pluck(:id, :user_id).to_h
    by_post.transform_values { |ids| ids.filter_map { |id| users[id] }.uniq.sort }
  end

  # Does `user` control `post`?
  def controls?(user, post)
    user_id = signed_in_id(user)
    return false if user_id.nil? || post&.id.nil?

    controller_user_ids([post]).fetch(post.id).include?(user_id)
  end

  # Every post `user` controls, asked from the user's end -- the form
  # query-level enforcement wants (an id list, as CreatorPrefixes gives).
  #
  # @return [Array<Integer>] sorted post ids
  def controlled_post_ids(user)
    user_id = signed_in_id(user)
    return [] if user_id.nil?

    gallery_post_ids(CreatorGallery.where(user_id: user_id).pluck(:id, :matrix_id))
  end

  # Every post these galleries control, from the galleries' end -- what
  # CreatorVisibility's whole-site form starts from.
  #
  # @param galleries [Array<Array(Integer, String)>] [id, matrix_id] pairs
  # @return [Array<Integer>] sorted post ids
  def gallery_post_ids(galleries)
    gallery_post_parts(galleries).flat_map { |part| part.pluck(:id) }.uniq.sort
  end

  # The same set as relations, so a caller narrows it further in SQL
  # (CreatorVisibility: only the gated ones) instead of carrying every id of
  # a large gallery into Ruby and back as an IN list (review, 2026-10-08).
  # TWO parts -- the recorded posts, driven by the creator index, and the
  # tagged ones, driven by the tag index -- never ORed into one: measured on
  # a 400,000-post dev DB (2026-10-08), an OR of the two with a tag filter
  # on top planned as a scan of every post.
  #
  # @return [Array<ActiveRecord::Relation<Post>>]
  def gallery_post_parts(galleries)
    return [] if galleries.empty?

    mxids = galleries.map { |_, mxid| mxid.downcase }
    recorded = Post.where(id: FourierPostCreator.where("lower(mxid) IN (?)", mxids).select(:post_id))
    tags = controlling_tags(galleries).values.flatten.uniq
    tags.empty? ? [recorded] : [recorded, tagged_posts(tags)]
  end

  # Every post these galleries control, as SQL selecting (post_id,
  # gallery_id) pairs -- the per-gallery form of gallery_post_parts, for
  # CreatorVisibility, where one gallery's settings apply to its own posts
  # only. ONE statement whatever the number of galleries: the recorded posts
  # through the creator index, the tagged ones by one GIN probe per
  # gallery's tags. Measured on a 400,000-post dev DB (2026-10-08): a
  # subselect per gallery (113 of them) planned at a cost past
  # jit_above_cost, and Postgres spent 0.86 s compiling it, every request.
  #
  # `only`: SQL selecting candidate (post_id, gallery_id) pairs -- a
  # creator's overrides -- to keep those the gallery controls, without
  # listing every post of the gallery. By joins from the candidates: as an
  # EXISTS inside an OR the planner hashed every creator row instead.
  #
  # @param galleries [Array<Array(Integer, String)>] [id, matrix_id] pairs
  # @return [String] SQL
  def controlled_pairs_sql(galleries, only: nil)
    return "SELECT NULL::bigint AS post_id, NULL::bigint AS gallery_id WHERE false" if galleries.empty?

    # The galleries' MXIDs as constants, so the creator index is probed for
    # each (measured: joining on lower(matrix_id) hashed every creator row).
    mxids = "VALUES #{galleries.map { |id, mxid| ActiveRecord::Base.sanitize_sql_array(["(?::bigint, ?)", Integer(id), mxid.downcase]) }.join(", ")}"
    tags = tag_values_sql(galleries)
    if only
      <<~SQL.squish
        SELECT f.post_id, m.gallery_id FROM (#{only}) o JOIN fourier_post_creators f ON f.post_id = o.post_id
          JOIN (#{mxids}) m(gallery_id, mxid) ON m.gallery_id = o.gallery_id AND lower(f.mxid) = m.mxid
        UNION ALL
        SELECT p.id AS post_id, t.gallery_id FROM (#{only}) o JOIN (#{tags}) t(gallery_id, tags) ON t.gallery_id = o.gallery_id
          JOIN posts p ON p.id = o.post_id AND string_to_array(p.tag_string, ' ') && t.tags
          WHERE NOT EXISTS (SELECT 1 FROM fourier_post_creators f WHERE f.post_id = p.id)
      SQL
    else
      <<~SQL.squish
        SELECT f.post_id, m.gallery_id FROM fourier_post_creators f JOIN (#{mxids}) m(gallery_id, mxid) ON lower(f.mxid) = m.mxid
          WHERE lower(f.mxid) IN (#{galleries.map { |_, mxid| ActiveRecord::Base.connection.quote(mxid.downcase) }.join(", ")})
        UNION ALL
        SELECT p.id AS post_id, t.gallery_id FROM (#{tags}) t(gallery_id, tags)
          JOIN posts p ON string_to_array(p.tag_string, ' ') && t.tags
          WHERE NOT EXISTS (SELECT 1 FROM fourier_post_creators f WHERE f.post_id = p.id)
      SQL
    end
  end

  # (gallery_id, tags) rows of the tags that confer control, as SQL.
  def tag_values_sql(galleries)
    rows = controlling_tags(galleries).reject { |_, tags| tags.empty? }
    return "SELECT NULL::bigint, NULL::text[] WHERE false" if rows.empty?

    "VALUES #{rows.map { |id, tags| ActiveRecord::Base.sanitize_sql_array(["(?::bigint, ARRAY[?]::text[])", id, tags]) }.join(", ")}"
  end

  # The creator tags that confer control on each of these galleries: the
  # master tag its Matrix account is named by, and every approved claim that
  # still passes the rule. Also what CreatorVisibility asks a release of --
  # a creator's OWN tags -- in one query for any number of galleries.
  #
  # @param galleries [Array<Array(Integer, String)>] [id, matrix_id] pairs
  # @return [Hash{Integer => Array<String>}] gallery id => tag names
  def controlling_tags(galleries)
    entries = prefix_entries
    claimed = ArtistClaim.where(creator_gallery_id: galleries.map(&:first)).standing(entries).group_by(&:second)

    galleries.to_h { |id, mxid| [id, (master_tags(mxid, entries) + claimed.fetch(id, []).map(&:first)).uniq] }
  end

  # The master-prefix tags naming `mxid` -- exactly the account master_mxid
  # would name for the tag, on THIS homeserver, so the two ends cannot
  # disagree over an MXID on another server; [] for any other server. Also
  # the base a creator's group names are built on (CreatorGroup).
  #
  # @return [Array<String>]
  def master_tags(mxid, entries = prefix_entries)
    localpart = ArtistClaim.localpart(mxid).to_s.downcase
    return [] unless localpart.present? && mxid.casecmp?("@#{localpart}:#{Danbooru.config.fourier_matrix_server_name}")

    entries.select { |e| ArtistClaim.master?(e) }.map { |e| "#{e.prefix}#{localpart}" }
  end

  # --- internals ---

  def prefix_entries = CreatorPrefixes.visibility_config[:entries]

  def entry_for(tag, entries)
    entries.find { |e| tag.start_with?(e.prefix) && tag.length > e.prefix.length }
  end

  def locked_tags(tag_string, entries)
    tag_string.to_s.split.select { |tag| entry_for(tag, entries) }
  end

  # The account a master-prefix tag names, on THIS homeserver
  # (FourierCreatorPrivacy.mxid_for_poster_tag reads poster tags the same way);
  # nil for any other tag.
  def master_mxid(tag, entries)
    entry = entry_for(tag, entries)
    return nil unless entry && ArtistClaim.master?(entry)

    "@#{tag.delete_prefix(entry.prefix)}:#{Danbooru.config.fourier_matrix_server_name}"
  end

  # lower(matrix_id) => gallery id
  def galleries_by_mxid(mxids)
    wanted = mxids.compact.map(&:downcase).uniq
    return {} if wanted.empty?

    CreatorGallery.where("lower(matrix_id) IN (?)", wanted).pluck(:matrix_id, :id).to_h { |mxid, id| [mxid.downcase, id] }
  end

  # tag => [gallery id] for the approved claims on these tags that still pass
  # the claim rule against the live list.
  def claimant_gallery_ids(tags, entries)
    return {} if tags.empty?

    ArtistClaim.where(tag_name: tags).standing(entries).group_by(&:first).transform_values { |rows| rows.map(&:second) }
  end

  # Posts carrying any of these tags that have NO recorded creator: a recorded
  # creator is the only controller of their post.
  def tagged_posts(tags)
    Post.where_array_includes_any("string_to_array(posts.tag_string, ' ')", tags)
        .where.not(id: FourierPostCreator.select(:post_id))
  end

  def signed_in_id(user)
    return nil if user.nil? || user.is_anonymous?

    user.id
  end
end
