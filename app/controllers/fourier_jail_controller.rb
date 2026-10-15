# frozen_string_literal: true

# The jail panel's door into the booru: releasing an image from
# fourier-sampling's troll jail (POST), and the booru's own jailings reported
# back to the panel (GET). Both answer only the jail panel's account
# (Danbooru.config.fourier_jail_release_names): operator ruling 2026-10-09,
# release happens only from the jail panel, by the jail account, and "The
# booru should obviously communicate back to the panel that is controlling
# the visibility of posts on the booru."
#
# WHY RELEASE IS ITS OWN VERB. Jailing an image deletes its booru post;
# releasing it has to bring the post back, and sampling could not, for two
# reasons measured against production on 2026-09-06:
#
#   1. fourier-sampling finds a post by searching `md5:<hash>`, and the search
#      index hides deleted posts from anyone below deleted_post_visibility_level
#      (ADMIN). The sampling bot is an Approver, so the lookup returned nothing.
#   2. Even with the id in hand, POST /post_approvals.json refuses: undeleting
#      is approving, and PostApproval rejects approving your own upload unless
#      you are an admin. The bot uploaded every post it jails. HTTP 422, "You
#      cannot approve a post you uploaded".
#
# Raising the bot to ADMIN or relaxing PostApprovalPolicy were rejected: the
# first hands an account whose key sits on a scraping box the run of the site,
# the second lets any approver undo a moderator's deletion of their own post.
# This is one verb, fork-local, that can ONLY reverse a jailing.
#
# WHAT IT RELEASES. A jailed post is a deleted post carrying troll_jail
# (operator ruling 2026-10-10: "Jailed means deleted"), and release takes the
# tag off AND undeletes it, in one save. It undoes a deletion only when that
# deletion is the jail's (Post#deletion_is_the_jails?): the latest logged
# deletion was made by a jail account -- sampling's, or the system user the
# booru's own jailings act as -- under the name it held then, and no
# undeletion has been logged since. Proved by WHO deleted, never by the
# reason text, which any approver types into DELETE /posts/:id. So:
#
#   - deleted, the jail's deletion: released (untagged and undeleted). That
#     includes a post whose tag is gone -- the pill's old jail-off left four
#     production posts deleted that way (2026-09-20);
#   - deleted, someone else's deletion: the jail's tag is lifted if it is
#     there, a reported jailing standing on that deletion is closed
#     (post_unjail, Post#jailing_stands?), and that deletion stands (422,
#     deleted: true, jailed: false) -- a moderator's deletion is never
#     undone through here, tagged or not;
#   - a legal hold (deleted "troll jail: radioactive" BY A JAIL ACCOUNT, ever):
#     nothing changes, ever (operator ruling 2026-10-08). An approver who
#     types those words has made an ordinary deletion, not a hold.
#
# `deleted` and `jailed` in a 422 are the post's state after the answer, so
# the caller can tell a finished release from a stuck one without reading the
# post back, which it cannot do for a deleted post.
#
# UNBANISH, the panel's other verb (operator ruling 2026-10-12): POST
# /fourier_jail/release.json with unbanish=<tag name>&by=<panel user>
# [&note=]. The panel lists the booru's banished tags (it reads their names
# in the quarantine document) and can take one off the list; the booru
# records which panel user pressed it in the mod log (tag_unbanish). It
# releases no jailed post -- that stays the per-post release above. Who in
# the panel may press it is the panel's own gate, not the booru's. A booru
# older than this verb answers an unbanish as a release with no md5: 422,
# "md5 must be 32 hex characters".
#
# GATE 3 FOR POSTS (fourier-basis docs/design/GATE3_MATRIX_POSTS.md), more
# modes of the same route -- no new route (ruling 2026-09-24):
#
#   POST {"placements": {...}} -- fourier-auth's placements feed: its answer
#     for each image (uploader, site asset, rooms), recorded by
#     MatrixPlacements; GET ?placements=cursor reads the two cursors. Both for
#     the GATE account alone: the reader on fourier_quarantine_reader_names
#     that is not a posting bot (fourier-auth's `gate`), above Member.
#   POST release_flagged=<name> | banish_flagged=<name>, by=, note= -- the
#     jail panel's Flagged tab (contract R1): TagQuarantine#release! and
#     #banish!, the mod log naming the panel user. "Not flagged" is 200 false.
#   GET ?quarantine=1&tag_id=<id>&after=<post id>&limit=25|50|100|200 -- one
#     tag's posts, a keyset page by id (contract R2), for the jail panel.
class FourierJailController < ApplicationController
  respond_to :json

  # Kept in step with fourier-sampling's JAIL_TAG (src/booru/jailSync.ts).
  JAIL_TAG = "troll_jail"

  # The panel user an unbanish names: a Matrix user id or a plain name. No
  # spaces or brackets, so it cannot carry DText into the mod log row.
  PANEL_USER = %r{\A[A-Za-z0-9@._=/+:-]{1,255}\z}

  NOT_THE_JAILS = "deleted, but not by the jail: its current deletion is not a jailing, and release never undoes another deletion"
  A_LEGAL_HOLD = "a legal hold (troll jail: radioactive): release never undeletes or untags one"

  # The most jail events one GET answers; the caller pages by `since`.
  EVENTS_PER_PAGE = 200

  # The page sizes of GET ?quarantine=1&tag_id= (contract R2).
  TAG_POST_LIMITS = [25, 50, 100, 200].freeze
  DEFAULT_TAG_POST_LIMIT = 50

  # How old a row must be before the cursor moves past it. Ids are handed
  # out at INSERT and rows become visible at COMMIT, so a jailing written
  # inside a longer transaction (the banished-tag failsafe runs inside an
  # upload's save) can appear BELOW a row already read, and a cursor that
  # had passed it would skip it forever (review of the 2026-10-10 build).
  # Younger rows are still listed -- the panel acts on them at once and a
  # re-read is harmless to it -- but the cursor stops before the first one.
  SETTLE = 30.seconds

  # GET /fourier_jail/release.json?since=<id>: every jailing the booru made
  # itself (the post_jail rows Post#jail_by_booru! and
  # Post#report_jailing_entered write) after the cursor,
  # oldest first. The panel cannot learn these any other way: its account
  # cannot read a deleted post, its versions, or the mod log rows naming one.
  # `cursor` is the last row's id older than SETTLE, to pass back as
  # `since`; `more` says a full page was answered and the cursor reached its
  # end. `jailed` is the post's state NOW, so a jailing already released or
  # undone is not listed as standing.
  #
  # GET /fourier_jail/release.json?quarantine=1[&after=<post id>]: the
  # QUARANTINE DOCUMENT instead (FLAGGED-TAG QUARANTINE, operator rulings
  # 2026-10-12) -- every post carrying a flagged or banished tag, by id, md5
  # and mxc, a snapshot, never an event feed; the names to a pipeline reader
  # only. Read by sample, tunnel and gate (fourier_quarantine_reader_names),
  # above Member level, never by anyone else. See TagQuarantine.document
  # for the body (the jail tag's posts are in it too).
  def index
    return placements_cursor if params.key?(:placements)
    return tag_posts if params[:quarantine].to_s.truthy? && params.key?(:tag_id)
    return quarantine_document if params[:quarantine].to_s.truthy?

    jail_panel_only!

    since = params[:since].to_i
    rows = ModAction.where(category: :post_jail, subject_type: "Post", creator: User.system)
                    .where("mod_actions.id > ?", since).order(:id).limit(EVENTS_PER_PAGE).to_a
    posts = Post.where(id: rows.map(&:subject_id)).index_by(&:id)
    events = rows.filter_map do |row|
      post = posts[row.subject_id]
      next if post.nil?

      reason = row.description.delete_prefix("jailed post ##{post.id}, reason: ")
      # The actor kind, from the reason. Only code writes these rows, as the
      # system user, so the set is closed: the pill's jail-on, the
      # banished-tag failsafe, and any other way into the jail
      # (Post#report_jailing_entered, FourierPastJailings), "booru user".
      actor, moderator = case reason
      when /\A#{Regexp.escape(Post::JAIL_DELETION_REASON)}moderator (\S+), from the post page\z/o then ["pill moderator", $1]
      when "#{Post::JAIL_DELETION_REASON}banished tag" then ["banished tag", nil]
      when /\A#{Regexp.escape(Post::JAIL_DELETION_REASON)}(\S+) banished a tag, from the review queue\z/o then ["banish", $1]
      when /\A#{Regexp.escape(Post::JAIL_DELETION_REASON)}(\S+) (?:tagged a deleted post|deleted a post tagged) /o then ["booru user", $1]
      else ["booru user", nil]
      end
      {
        id: row.id, post_id: post.id, md5: post.md5, reason: reason,
        actor: actor, moderator: moderator,
        at: row.created_at.iso8601, tags: post.tag_string,
        jailed: post.jailed?, deleted: post.is_deleted?, hold: post.legal_hold?,
      }
    end
    settled = rows.take_while { |row| row.created_at <= SETTLE.ago }
    cursor = settled.last&.id || since
    render json: { events: events, cursor: cursor, more: rows.size == EVENTS_PER_PAGE && settled.size == rows.size }
  end

  def create
    return placements if params.key?(:placements)

    jail_panel_only!
    return unbanish if params.key?(:unbanish)
    return flagged_verdict(:release) if params.key?(:release_flagged)
    return flagged_verdict(:banish) if params.key?(:banish_flagged)

    # 422, not 404, for a malformed md5. A 404 from this route has to mean one
    # thing only -- "this booru has no release endpoint" -- so the caller can
    # tell an undeployed fork from a bad request without guessing.
    md5 = params[:md5].to_s
    unless md5.match?(/\A[0-9a-f]{32}\z/)
      return render json: { released: false, reason: "md5 must be 32 hex characters" }, status: 422
    end

    # Post.find_by, NOT a tag search: the model has no opinion about who may
    # see the post, which is why the search route could not see these and
    # this one can. A missing post is reported in the BODY, not as a 404, so
    # "no such image" never looks like "no release endpoint".
    post = Post.find_by(md5: md5)
    if post.nil?
      return render json: { released: false, reason: "no such post" }, status: 200
    end

    # The verdict and the write under ONE lock: decided outside it, a
    # moderator's deletion landing between the two would be undone by a
    # verdict about the deletion before it.
    status, body = post.with_lock { decide!(post) }
    render json: body.merge(post_id: post.id), status: status
  end

  private

  # Take a banished tag off the list, for the jail panel (see the header).
  # A name that is not banished is answered in the body, 200, so a retry of
  # an unbanish that already landed is not a failure.
  def unbanish
    name = params[:unbanish].to_s
    panel_user = params[:by].to_s
    unless panel_user.match?(PANEL_USER)
      return render json: { unbanished: false, reason: "by must name the jail panel user who pressed unbanish (their Matrix id, e.g. @name:41chan.net: 1-255 of A-Z a-z 0-9 @ . _ = / + : -); the booru records it in the mod log" }, status: 422
    end

    not_banished = { unbanished: false, tag: name, reason: "not banished: no banished tag has this name" }
    row = TagQuarantine.banished.joins(:tag).find_by(tags: { name: name })
    return render json: not_banished if row.nil?

    begin
      row.unbanish!(by: CurrentUser.user, panel_user: panel_user, note: params[:note].to_s)
    rescue TagQuarantine::Refused, ActiveRecord::RecordNotFound
      # Unbanished or changed by another request since the lookup.
      return render json: not_banished
    end
    render json: { unbanished: true, tag: name }
  end

  # Record fourier-auth's answers for a batch of images (see MatrixPlacements
  # for the rules). A malformed push as a whole is 422 with what to send; a
  # malformed item is counted in the answer and never fails the batch.
  def placements
    gate_account_only!
    payload = params[:placements]
    payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
    render json: MatrixPlacements.apply!(payload)
  rescue MatrixPlacements::Invalid => e
    render json: { error: e.message }, status: 422
  end

  # GET ?placements=cursor: where each placement reader has pushed up to, as
  # recorded -- what fourier-auth resumes from.
  def placements_cursor
    gate_account_only!
    unless params[:placements] == "cursor"
      return render json: { error: "placements=#{params[:placements].to_s.truncate(40)} is not a read this booru answers; ask placements=cursor" }, status: 422
    end

    render json: { cursor: MatrixPlacementCursor.answer }
  end

  # Release or banish a FLAGGED tag for the jail panel's Flagged tab (see the
  # header). A name that is not flagged -- unknown, back to normal, or
  # banished already -- is answered 200 false, so a retry of a verdict that
  # landed is not a failure.
  def flagged_verdict(verdict)
    key, answer = (verdict == :release) ? %i[release_flagged released_flagged] : %i[banish_flagged banished_flagged]
    name = params[key].to_s
    panel_user = params[:by].to_s
    unless panel_user.match?(PANEL_USER)
      return render json: { answer => false, tag: name, reason: "by must name the jail panel user who pressed #{(verdict == :release) ? "Release" : "Banish"} (their Matrix id, e.g. @name:41chan.net: 1-255 of A-Z a-z 0-9 @ . _ = / + : -); the booru records it in the mod log" }, status: 422
    end

    not_flagged = { answer => false, tag: name, reason: "not flagged: no flagged tag has this name (already released, already banished, or never flagged)" }
    row = TagQuarantine.flagged.joins(:tag).find_by(tags: { name: name })
    return render json: not_flagged if row.nil?

    begin
      TagQuarantine.transaction do
        row.lock!
        raise TagQuarantine::Refused, "no longer flagged" unless row.flagged?

        if verdict == :release
          row.release!(by: CurrentUser.user, note: params[:note].to_s, panel_user: panel_user)
        else
          row.banish!(by: CurrentUser.user, note: params[:note].to_s, panel_user: panel_user)
        end
      end
    rescue TagQuarantine::Refused, ActiveRecord::RecordNotFound
      # Released or banished by another request since the lookup.
      return render json: not_flagged
    end
    render json: { answer => true, tag: name }
  end

  # One tag's posts for the jail panel (contract R2): a keyset page by post
  # id over the tag index, deleted and jailed posts included, never the
  # whole quarantine document. `generation` is the quarantined names'
  # (TagQuarantine.names_generation): it moves when a flag or a banishment
  # changes, so the panel knows to re-read.
  def tag_posts
    jail_panel_only!
    limit = params[:limit].presence ? Integer(params[:limit].to_s, 10, exception: false) : DEFAULT_TAG_POST_LIMIT
    unless TAG_POST_LIMITS.include?(limit)
      return render json: { error: "limit must be one of #{TAG_POST_LIMITS.join(", ")} (posts per page), got #{params[:limit].to_s.truncate(20).inspect}" }, status: 422
    end

    after = [params[:after].to_i, 0].max
    generation = TagQuarantine.names_generation
    tag = Tag.find_by(id: params[:tag_id].to_i)
    if tag.nil?
      return render json: { tag: nil, reason: "no tag has id #{params[:tag_id].to_s.truncate(20)}", generation: generation, posts: [], next_after: nil }
    end

    rows = Post.where_array_includes_all("string_to_array(posts.tag_string, ' ')", [tag.name])
               .where("posts.id > ?", after).order(:id).limit(limit + 1).includes(:uploader).to_a
    page = rows.first(limit)
    flagged = TagQuarantine.flagged_names
    banished = TagQuarantine.banished_names
    holds = page.empty? ? Set.new : Post.jail_deletions(Post::LEGAL_HOLD_REASON).where(subject_id: page.map(&:id)).distinct.pluck(:subject_id).to_set
    posts = page.map do |post|
      {
        id: post.id, md5: post.md5, mxc: post.source.to_s.start_with?("mxc://") ? post.source : nil,
        file_ext: post.file_ext, rating: post.rating, uploader: post.uploader&.name, created_at: post.created_at.iso8601,
        deleted: post.is_deleted?, jailed: post.jailed?, hold: holds.include?(post.id),
        flagged: post.tag_array.select { |name| flagged.include?(name) }, banished: post.tag_array.any? { |name| banished.include?(name) },
      }
    end
    render json: {
      tag: { id: tag.id, name: tag.name, post_count: tag.post_count },
      generation: generation,
      posts: posts,
      next_after: (rows.size > limit) ? page.last.id : nil,
    }
  end

  # The quarantine document, ETag'd per generation and per kind of reader
  # (the names go to the pipeline alone, so the two bodies differ).
  def quarantine_document
    quarantine_reader!
    user = CurrentUser.user

    after = params[:after].presence&.to_i
    doc = TagQuarantine.document(reader: user, after: after)
    etag = %{"#{doc[:generation]}-#{TagBanishment.pipeline?(user) ? "n" : "p"}"}
    response.headers["ETag"] = etag
    response.headers["Cache-Control"] = "private, no-cache"
    if request.headers["If-None-Match"].to_s.split(/\s*,\s*/).include?(etag)
      head 304
    else
      render json: doc
    end
  end

  # The list trusts names, and a name is anyone's to register: whoever
  # signed up as "gate" before the real account existed would read every
  # quarantined md5 and mxc. So a reader must ALSO be above Member -- a fresh
  # registration is Member, and only an admin raises an account past it
  # (session ruling 2026-10-12).
  def quarantine_reader!
    names = Array(Danbooru.config.fourier_quarantine_reader_names).map { |name| name.to_s.downcase }
    user = CurrentUser.user
    unless !user.is_anonymous? && names.include?(user.name.to_s.downcase)
      raise User::PrivilegeError, "the quarantine document is read by fourier_quarantine_reader_names alone (Danbooru.config); add this account there, or call as one of: #{names.join(", ").presence || "nobody"}"
    end
    unless user.level > User::Levels::MEMBER
      raise User::PrivilegeError, "#{user.name} is on fourier_quarantine_reader_names but is #{user.level_string}: a reader must be above Member, so an account that merely registered the name cannot read the quarantine document. If this is the real #{user.name} account, an admin promotes it (Gold or above) at /admin/users/#{user.id}/edit; if not, rename or ban it and create the real one"
    end
    skip_authorization # gated on the reader list above
  end

  # fourier-auth's account: a quarantine reader (above) that is not a
  # posting bot -- the pipeline's accounts read the document but never push
  # placements.
  def gate_account_only!
    quarantine_reader!
    return unless TagBanishment.pipeline?(CurrentUser.user)

    raise User::PrivilegeError, "placements are pushed by fourier-auth's account alone: the account on fourier_quarantine_reader_names that is not a posting bot (fourier_posting_bot_names / creator_prefixes.yml editors). #{CurrentUser.user.name} is a posting bot; call as fourier-auth's account"
  end

  def jail_panel_only!
    names = Array(Danbooru.config.fourier_jail_release_names).map { |name| name.to_s.downcase }
    unless CurrentUser.user.is_approver? && names.include?(CurrentUser.user.name.to_s.downcase)
      raise User::PrivilegeError, "The troll jail is released from the jail panel (fourier-sampling) alone: only #{names.join(", ").presence || "nobody"} may call this, as Danbooru.config.fourier_jail_release_names says. Unjail the image in the jail panel."
    end
    skip_authorization # gated on the jail panel's account above
  end

  # [status, body] for a post read under the lock, acting as it says.
  def decide!(post)
    tagged = post.has_tag?(JAIL_TAG)
    if post.legal_hold?
      return [422, { released: false, reason: A_LEGAL_HOLD, deleted: post.is_deleted?, jailed: tagged || post.jailed?, hold: true }]
    end
    unless post.is_deleted?
      # Idempotent on purpose: a retry of a release that already landed must
      # not look like a failure, or the caller retries forever -- so a live
      # post the jail once deleted is "already active". A live post still
      # carrying the tag (an older release that left the untag to the caller)
      # is untagged, which finishes the release. A live post the jail never
      # touched is "not jailed".
      return [422, { released: false, reason: "not jailed", deleted: false, jailed: false }] unless tagged || Post.jail_deletions.exists?(subject_id: post.id)

      untag!(post) if tagged
      return [200, { released: false, reason: "already active" }]
    end

    if post.deletion_is_the_jails?
      release!(post)
      [200, { released: true }]
    else
      # Another account's deletion: the jail's part is lifted -- the tag, and
      # a reported jailing standing on that deletion, closed on the booru's
      # log (post_unjail) -- and that deletion stands.
      untag!(post) if tagged
      ModAction.log("unjailed post ##{post.id}, its other deletion left standing", :post_unjail, subject: post, user: CurrentUser.user) if post.jailing_stands?
      [422, { released: false, reason: NOT_THE_JAILS, deleted: true, jailed: false }]
    end
  end

  # What PostApproval#approve_post does, minus the approval record it cannot
  # create, plus the untag: one save, so undeleted and untagged land together
  # or not at all. Same ModAction as an approval's undeletion, which is also
  # what ends the jail's deletion for Post#deletion_is_the_jails?.
  def release!(post)
    post.flags.pending.update!(status: :rejected)
    post.appeals.pending.update!(status: :succeeded)
    post.remove_tag(JAIL_TAG) if post.has_tag?(JAIL_TAG)
    post.update!(approver: CurrentUser.user, is_flagged: false, is_pending: false, is_deleted: false)
    ModAction.log("undeleted post ##{post.id}", :post_undelete, subject: post, user: CurrentUser.user)
  end

  def untag!(post)
    post.remove_tag(JAIL_TAG)
    post.save!
  end
end
