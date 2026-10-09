# frozen_string_literal: true

# Creator Gallery: a user's individualized presentation page. Reads are public;
# ALL writes are gated to the page's Matrix identity (via FourierIdentity) or an
# admin. A non-admin can only ever create/edit the page matching their own
# verified MXID.
#
# WHOSE ACCOUNT IT IS (design CREATOR_VISIBILITY section 9, ruled 2026-10-07).
# user_id is the only stored link from a Matrix identity to a booru account,
# and CreatorControl reads it: whoever it names controls the creator's posts.
# So it is set only under BOTH sessions at once -- the verified identity
# matching the page and a signed-in, unbanned booru account -- at creation, or
# later by linking. An admin may make or edit a page; an admin is never
# recorded as its account, and nobody re-links a page already linked. An
# admin may UNLINK one (logged, admin-only), which is how a page made before
# this rule, carrying the admin's own id, is put right.
#
# CLAIMS. Filing an ArtistClaim on a creator tag for the page's linked account
# is that account's act alone, under that verified identity: the claim is the
# creator's word. An admin decides it (Admin::ArtistClaimsController).
#
# ONE ROUTE. Linking, unlinking and filing a claim are explicit acts on the
# gallery, so they ride its own update route (PATCH creators/:slug with
# link_account, unlink_account or claim_tag) rather than new routes (operator
# ruling 2026-09-24: "do not build new routes, reuse existing routes").
#
# THE PANEL (CREATOR_VISIBILITY sections 4-5 and Q5; built 2026-10-09). Who
# sees a creator's posts is set on this page's edit screen and written through
# PATCH creators/:slug with panel=<act>, one act from a closed list (routes
# ruling 2026-09-24: no new routes). Writing needs what claims and linking
# need -- the verified identity AND the page's linked booru account, signed
# in and unbanned -- or an admin, whose every write the models log where
# only admins read. Moderators never reach it (Q2). Each write runs under
# the gallery's row lock and asks again on the reloaded row, so an unlink or
# a ban that landed after the page loaded refuses it; every id is resolved
# through this gallery, so a hand-made form cannot reach another creator's
# rows, and a refusal never says whether such a row exists.
#
# JOIN REQUESTS (Q5) ride the same PATCH from a VISITOR (join_group,
# join_withdraw): the one write here that is not the owner's. `join_request?`
# is the single predicate both the owner gate's exemption and update's
# first-line dispatch read, so the two cannot disagree and a join PATCH can
# never reach a link, a claim, the panel or the settings.
#
# THE IDENTITY HEADER IS A BROWSER COOKIE. fourier-auth turns the visitor's
# fourier_session cookie (SameSite=lax, sent from every 41chan.net subdomain)
# into X-Fourier-Identity, and ApplicationController skips CSRF protection for
# an API-key request. Honouring both on one request would let a page on any
# subdomain act as the visitor's Matrix identity under the API key's booru
# account. So the header counts only on a request carrying the booru's own
# session (owner_identity?).
class CreatorGalleriesController < ApplicationController
  layout "sidebar"

  before_action :load_gallery, only: %i[show edit update add_post remove_post create_message destroy_message]
  # A visitor's join request is the only write a non-owner makes here; the
  # same join_request? decides update's first line (2026-10-09).
  before_action :require_owner!, only: %i[edit update add_post remove_post create_message destroy_message], unless: :join_request?

  # The panel's acts (PATCH creators/:slug, panel=<act>), each with the block
  # of the panel it answers on -- :group for an act on one group, which
  # comes back with that group open (open_group, by URL only: the panel
  # remembers the creator's place for the next page and nothing more).
  # Anything else is a 400.
  PANEL_ACTS = {
    "default_audience" => "creator-panel-default",
    "post_audience" => "creator-panel-posts",
    "make_group" => "creator-panel-groups",
    "group_requests" => :group,
    "dissolve_group" => "creator-panel-groups",
    "add_member" => :group,
    "remove_member" => :group,
    "set_rule" => "creator-panel-people",
    "clear_rule" => "creator-panel-people",
    "approve_request" => "creator-panel-requests",
    "refuse_request" => "creator-panel-requests",
  }.freeze

  # A panel write refused before it reached a model, with the words to show.
  class Refused < StandardError; end

  NOT_YOUR_POST = "Post #%s is not one of your posts (or does not exist): only posts you sent from Matrix, or that carry " \
                  "a creator tag you have an approved claim on, are yours to set."
  NOT_TAKING_REQUESTS = "That group is not taking requests. The creator decides which groups people can ask to join."
  # Q8: a block beats membership, so letting a blocked person into a group
  # opens nothing, and the notice says so (repair, 2026-10-09).
  BLOCK_BEATS_MEMBERSHIP = "you keep them out of all your posts, and a block beats membership: remove it under People you let in or keep out to let them see."
  # Why a post's ticked groups were dropped, per audience: Everyone lists
  # groups too (the widening past the level gate), so "only Members of my
  # groups lists groups" would be false.
  GROUPS_NOT_KEPT = {
    "private" => "Groups never open a private post, so the ticked groups were not kept.",
    "inherit" => "It now follows your default, which has its own groups; the ticked groups were not kept.",
  }.freeze

  def index
    skip_authorization
    @galleries = CreatorGallery.order(updated_at: :desc).limit(60)
  end

  # The visitor's own standing with this creator's groups, and nothing else:
  # the groups open to requests, the viewer's own memberships and their latest
  # request per group (CREATOR_VISIBILITY Q5; the creator panel, 2026-10-09).
  # Nobody else's name, no counts. A closed group is listed only to a viewer
  # with something of their own in it -- a current membership, a request
  # still waiting (which they may withdraw), or a refusal still standing --
  # so closing a group never hides a viewer's own request from them.
  def show
    skip_authorization
    viewer = CurrentUser.user
    return if viewer.is_anonymous? || viewer.is_banned? || viewer.id == @gallery.user_id
    return if CreatorUserRule.exists?(creator_gallery: @gallery, user: viewer, post_id: nil, rule: CreatorUserRule::BLOCK)

    groups = @gallery.creator_groups
    @join_memberships = CreatorGroupMembership.where(user: viewer, creator_group_id: groups.select(:id)).index_by(&:creator_group_id)
    @join_requests = CreatorJoinRequest.where(user: viewer, creator_group_id: groups.select(:id)).order(:created_at, :id).index_by(&:creator_group_id)
    standing = @join_requests.values.select { |asked| asked.pending? || asked.refusal_standing? }.map(&:creator_group_id)
    mine = @join_memberships.values.select(&:active?).map(&:creator_group_id) + standing
    @join_groups = groups.where(open_to_requests: true).or(groups.where(id: mine)).order(Arel.sql("tier ASC NULLS LAST"), :name).to_a
  end

  def new
    skip_authorization
    @gallery = CreatorGallery.new
  end

  def edit
    skip_authorization
    @panel_refusal = panel_refusal
    @claims = @gallery.artist_claims.order(created_at: :desc, id: :desc)
    @signed_in_owner = owner_signed_in?
    # The creator tags this page may claim: one per non-master prefix in the
    # live list, named for the page's Matrix localpart, among tags that exist.
    # Offered to the linked account only, and only where the model would take
    # the claim -- the button and the refusal cannot disagree.
    localpart = ArtistClaim.localpart(@gallery.matrix_id).to_s.downcase
    tags = @signed_in_owner ? CreatorPrefixes.entries.reject { |e| ArtistClaim.master?(e) }.map { |e| "#{e.prefix}#{localpart}" } : []
    @claim_offers = tags.select do |tag|
      (Artist.exists?(name: tag) || Tag.exists?(name: tag)) && ArtistClaim.prepare(@gallery, CurrentUser.user, tag).second.nil?
    end
  rescue CreatorPrefixes::ConfigError => e
    @claim_offers = []
    flash.now[:notice] = "Creator tags cannot be claimed right now: #{e.message}"
  end

  # Claim your page. A non-admin may only create the gallery for their own
  # verified identity; an admin may pass an explicit matrix_id.
  #
  # The account recorded is the one signed in UNDER that verified identity.
  # An admin making a page for someone else's MXID is not that person, so
  # the page starts unlinked and its owner links it (link_account).
  def create
    skip_authorization
    verified = api_request? ? nil : FourierIdentity.current(request)
    mxid = verified
    if mxid.blank? && CurrentUser.user.is_admin?
      mxid = params.dig(:creator_gallery, :matrix_id).to_s.strip
    end
    raise User::PrivilegeError, "Sign in with your Matrix identity to create a page." if mxid.blank?

    @gallery = CreatorGallery.new(gallery_params)
    @gallery.assign_attributes(matrix_id: mxid, slug: slug_from(mxid), user_id: verified.present? ? CurrentUser.user.id : nil)
    if @gallery.save
      redirect_to creator_gallery_path(@gallery)
    else
      render :new, status: 422
    end
  end

  def update
    skip_authorization
    # FIRST, and returning: require_owner! was skipped for exactly this
    # (join_request?, 2026-10-09), so nothing below may run for it.
    return file_join_request if join_request?
    return link_account if params[:link_account].present?
    return unlink_account if params[:unlink_account].present?
    return file_claim(params[:claim_tag]) if params[:claim_tag].present?
    return panel_write if params[:panel].present?

    if @gallery.update(gallery_params)
      redirect_to creator_gallery_path(@gallery)
    else
      render :edit, status: 422
    end
  end

  # --- curated posts ---
  def add_post
    skip_authorization
    # A post hidden from the curator is "not found" (Post.find_visible!).
    post = Post.find_visible!(params.expect(:post_id))
    next_pos = (@gallery.creator_gallery_posts.maximum(:position) || 0) + 1
    @gallery.creator_gallery_posts.create_or_find_by(post_id: post.id) { |cgp| cgp.position = next_pos }
    respond_change
  end

  def remove_post
    skip_authorization
    @gallery.creator_gallery_posts.where(post_id: params[:post_id]).destroy_all
    respond_change
  end

  # --- blog messages ---
  def create_message
    skip_authorization
    @gallery.creator_gallery_messages.create(body: params.expect(creator_gallery_message: [:body])[:body])
    respond_change
  end

  def destroy_message
    skip_authorization
    @gallery.creator_gallery_messages.where(id: params[:message_id]).destroy_all
    respond_change
  end

  private

  # --- account link and creator claims (reached through update) ---

  # Link this page to the signed-in booru account of its verified owner. An
  # explicit act, never a side effect of visiting: it decides whose posts these
  # are. A page already linked stays as it is -- an admin unlinks it first.
  def link_account
    require_owner_signed_in!
    notice = @gallery.with_lock do
      if @gallery.user_id == CurrentUser.user.id
        "This page is already linked to your booru account."
      elsif @gallery.user_id.present?
        "This page is already linked to another booru account. Ask an admin to unlink it (an admin can, from " \
          "this page's edit screen), then link your own account here."
      else
        @gallery.update!(user_id: CurrentUser.user.id)
        "Linked to your booru account, #{CurrentUser.user.name}."
      end
    end
    redirect_to edit_creator_gallery_path(@gallery), notice: notice
  end

  # Clear the page's booru account: an admin's correction, logged where only
  # admins read it, after which the verified owner links their own account.
  def unlink_account
    raise User::PrivilegeError, "Only an admin can unlink a creator page from its booru account." unless CurrentUser.user.is_admin?

    notice = @gallery.with_lock do
      linked = @gallery.user
      if linked.nil?
        "This page is not linked to a booru account."
      else
        @gallery.update!(user_id: nil)
        ModAction.log("unlinked the creator page #{@gallery.matrix_id} from the booru account \"#{linked.name}\":#{Routes.user_path(linked)}",
                      :creator_gallery_unlink, subject: linked, user: CurrentUser.user)
        "Unlinked from #{linked.name}. The page's owner can now link their own account here."
      end
    end
    redirect_to edit_creator_gallery_path(@gallery), notice: notice
  end

  # File a claim on a creator tag for this page's linked account, making the
  # Artist entry when the tag has none, as /artists would, in the same save:
  # a refused claim leaves no entry behind. ArtistClaim.prepare decides, the
  # same check that put the button on the page; its words are the answer.
  def file_claim(tag_name)
    require_owner_signed_in!
    raise User::PrivilegeError, "Link this page to your booru account before claiming a creator tag." if @gallery.user_id != CurrentUser.user.id

    claim, refusal = ArtistClaim.prepare(@gallery, CurrentUser.user, tag_name)
    return redirect_back_or_to(edit_creator_gallery_path(@gallery), notice: "Not filed: #{refusal}") if refusal

    ArtistClaim.transaction do
      claim.artist.save! if claim.artist.new_record?
      claim.save!
    end
    redirect_back_or_to edit_creator_gallery_path(@gallery), notice: "Claim on #{claim.tag_name} filed. An admin will review it."
  rescue ActiveRecord::RecordInvalid => e # a race with another filing, between the check and the save
    redirect_back_or_to edit_creator_gallery_path(@gallery), notice: "Not filed: #{e.record.errors.full_messages.join("; ")}"
  end

  # --- join requests: the visitor's acts (reached through update) ---

  # A visitor's own request: filed into a group this creator opened, or
  # withdrawn while it waits. Signed out gets the members-only 404, as every
  # write here does. Missing, closed and another creator's group read alike.
  def file_join_request
    MembersOnly.require!(CurrentUser.user)
    viewer = CurrentUser.user
    notice = if params.key?(:join_withdraw)
      asked = CreatorJoinRequest.where(user: viewer, creator_group_id: @gallery.creator_groups.select(:id)).find_by(id: params[:join_withdraw])
      if asked.nil?
        "There is no request of yours to withdraw here; it may already have been answered."
      else
        asked.withdraw!(by: viewer)
        "Your request to join #{asked.creator_group.name} is withdrawn."
      end
    else
      group = @gallery.creator_groups.where(open_to_requests: true).find_by(id: params[:join_group])
      if group.nil?
        NOT_TAKING_REQUESTS
      else
        CreatorJoinRequest.file!(group, viewer, note: params[:note].to_s)
        "You asked to join #{group.name}. #{@gallery.title.presence || @gallery.slug} decides; the answer shows here."
      end
    end
    redirect_to creator_gallery_path(@gallery, anchor: "creator-join"), notice: notice
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    words = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.join(" ") : "You already asked to join that group."
    redirect_to creator_gallery_path(@gallery, anchor: "creator-join"), notice: words
  end

  # Shared by the owner gate's exemption and update's first line: one method,
  # so the two can never disagree about which request skipped the gate.
  def join_request?
    action_name == "update" && (params.key?(:join_group) || params.key?(:join_withdraw))
  end

  # --- the panel: the creator's acts (reached through update) ---

  # Why this viewer may not use the panel, in words that say what to do, or
  # nil when they may: an admin, or the verified owner signed in as the
  # page's linked, unbanned booru account.
  def panel_refusal
    return nil if CurrentUser.user.is_admin?
    return nil if owner_signed_in? && @gallery.user_id == CurrentUser.user.id

    if @gallery.user.nil?
      "Who sees your posts is set here once this page is linked to your booru account. Use \"Link this page to my booru " \
        "account\" below, signed in to the booru as yourself."
    elsif @gallery.user.is_banned? || CurrentUser.user.is_banned?
      "A banned account cannot change who sees its posts. Ask an admin."
    else
      "Sign in to the booru as #{@gallery.user.name} to manage who sees your posts."
    end
  end

  def require_panel_writer!
    refusal = panel_refusal
    raise User::PrivilegeError, refusal if refusal
  end

  # One act, under the gallery's row lock, asked again on the reloaded row;
  # the model call is the write, and logs itself.
  def panel_write
    act = params[:panel].to_s
    raise ActionController::BadRequest, "Unknown panel action \"#{act}\". Reload the page and try again." unless PANEL_ACTS.key?(act)

    require_panel_writer!
    # A write on one group, refused or not, comes back with that group open.
    stay = (PANEL_ACTS.fetch(act) == :group) ? { open_group: params[:group_id].to_i } : {}
    notice, extra = @gallery.with_lock do
      require_panel_writer!
      send(:"panel_#{act}")
    end
    panel_redirect(act, stay.merge(extra.to_h), notice)
  rescue Refused, CreatorAudienceGroup::Refusal => e
    panel_redirect(act, stay, e.message)
  rescue ActiveRecord::RecordInvalid => e
    panel_redirect(act, stay, e.record.errors.full_messages.join(" "))
  rescue ActiveRecord::RecordNotUnique
    panel_redirect(act, stay, "Someone else changed this at the same moment. Reload the page and try again.")
  rescue CreatorPrefixes::ConfigError => e
    panel_redirect(act, stay, "Not saved: the creator prefix list cannot be read right now (#{e.message}). Try again once it can.")
  end

  # Back to the block the act answers on, or to the one group left open.
  def panel_redirect(act, place, notice)
    anchor = place[:open_group] ? "creator-panel-group-#{place[:open_group]}" : PANEL_ACTS.fetch(act)
    redirect_to edit_creator_gallery_path(@gallery, **place, anchor: anchor), notice: notice
  end

  def panel_default_audience
    audience = params[:audience].to_s
    raise Refused, "Choose Everyone, Members of my groups or Private, then save." unless audience.in?(CreatorGallery::AUDIENCES)

    ids = panel_group_ids
    dropped = ids.any? && audience == "private"
    ids = [] if dropped
    changed = @gallery.set_default_audience!(audience, by: CurrentUser.user, group_ids: ids)
    # Dropped ticks are said even when nothing else changed.
    not_kept = " #{GROUPS_NOT_KEPT.fetch(audience)}" if dropped
    return "Nothing changed.#{not_kept}" if changed.nil?

    labels = @gallery.creator_groups.where(name: changed).order(:name).map(&:label)
    "Who sees your posts: #{CreatorGallery.audience_words(audience, labels)}.#{not_kept}"
  end

  def panel_post_audience
    post = panel_post(params[:post_id])
    audience = params[:audience].to_s
    raise Refused, "Choose your default, Everyone, Members of my groups or Private, then save." unless audience.in?(CreatorPostAudience::AUDIENCES)

    ids = panel_group_ids
    dropped = ids.any? && audience.in?(CreatorAudienceGroup::GROUPLESS)
    ids = [] if dropped
    row = CreatorPostAudience.set!(post, gallery: @gallery, audience: audience, by: CurrentUser.user, group_ids: ids)
    words = (audience == "inherit") ? "back to your default" : CreatorGallery.audience_words(audience, @gallery.creator_groups.where(id: ids).order(:name).map(&:label))
    not_kept = " #{GROUPS_NOT_KEPT.fetch(audience)}" if dropped
    notice = row.nil? ? "Nothing changed.#{not_kept}" : "Post ##{post.id}: #{words}.#{not_kept}"
    [notice, { post_id: post.id }]
  end

  def panel_make_group
    base = CreatorControl.master_tags(@gallery.matrix_id).first
    if base.nil?
      master = CreatorPrefixes.visibility_config[:entries].find { |e| ArtistClaim.master?(e) }&.prefix
      raise Refused, "Groups are named for your #{master} tag, which only a Matrix account on #{Danbooru.config.fourier_matrix_server_name} has; #{@gallery.matrix_id} is not."
    end

    suffix = params[:suffix].to_s.strip.downcase
    group = CreatorGroup.make!(@gallery, name: "#{base}_#{suffix}", tier: suffix[/\Atier_(\d+)\z/, 1]&.to_i, by: CurrentUser.user,
                                         open_to_requests: params[:open_to_requests].to_s.truthy?)
    ["Made #{group.name}#{", open to requests" if group.open_to_requests}.", { open_group: group.id }]
  end

  def panel_group_requests
    group = panel_group
    open = params[:open_to_requests].to_s.truthy?
    return "Nothing changed." if group.open_to_requests!(open, by: CurrentUser.user).nil?

    open ? "People can now ask to join #{group.name} from your page." : "#{group.name} no longer takes requests; any already waiting stay for you to answer."
  end

  def panel_dissolve_group
    group = panel_group
    group.dissolve!(by: CurrentUser.user)
    "Dissolved #{group.name}."
  end

  def panel_add_member
    group = panel_group
    user = panel_user(params[:user_name])
    until_time = panel_until
    membership = group.add_member!(user, by: CurrentUser.user, expires_at: until_time)
    return "Nothing changed." if membership.nil?

    let_in_words(user, group, until_time)
  end

  def panel_remove_member
    group = panel_group
    member = group.memberships.find_by(user_id: params[:user_id])&.user
    raise Refused, "That person is not in #{group.name} (they may already have been removed)." if member.nil?

    group.remove_member!(member, by: CurrentUser.user)
    "#{member.name} is no longer in #{group.name}."
  end

  def panel_set_rule
    user = panel_user(params[:user_name])
    post = params[:post_id].present? ? panel_post(params[:post_id]) : nil
    rule = params[:rule].to_s
    raise Refused, "Choose Let in or Keep out." unless rule.in?(CreatorUserRule::RULES)

    row = CreatorUserRule.set!(@gallery, user, rule: rule, by: CurrentUser.user, post: post)
    return "Nothing changed." if row.nil?

    where = post ? "post ##{post.id}" : "all your posts"
    (rule == CreatorUserRule::BLOCK) ? "#{user.name} is kept out of #{where}." : "#{user.name} is let in to #{where}."
  end

  def panel_clear_rule
    rule = CreatorUserRule.where(creator_gallery: @gallery, post_id: params[:post_id].presence).find_by(user_id: params[:user_id])
    raise Refused, "There is no such setting on your posts (it may already be gone)." if rule.nil?

    CreatorUserRule.clear!(@gallery, rule.user, by: CurrentUser.user, post: rule.post)
    "Removed the setting for #{rule.user.name}#{" on post ##{rule.post_id}" if rule.post_id}."
  end

  def panel_approve_request
    asked = panel_request
    until_time = panel_until
    asked.approve!(by: CurrentUser.user, expires_at: until_time)
    let_in_words(asked.user, asked.creator_group, until_time, kept: asked.kept_membership)
  end

  # What letting `user` into `group` did, built from what was written: a
  # membership already held is kept with its own end (approve!), and a
  # creator-wide block still keeps them out (Q8). Never a date or an access
  # that enforcement will not apply.
  def let_in_words(user, group, until_time, kept: nil)
    blocked = CreatorUserRule.exists?(creator_gallery: @gallery, user: user, post_id: nil, rule: CreatorUserRule::BLOCK)
    if kept
      ends = kept.expires_at ? "until #{kept.expires_at.to_date}" : "no end"
      "#{user.name} was already in #{group.name} (#{ends}); that membership was kept#{" and the date you gave was not applied" if until_time}. " \
        "Use Renew or Add someone on the group to change its end.#{" #{BLOCK_BEATS_MEMBERSHIP.upcase_first}" if blocked}"
    elsif blocked
      "#{user.name} is now in #{group.name}#{", until #{until_time.to_date}" if until_time}, but #{BLOCK_BEATS_MEMBERSHIP}"
    else
      "#{user.name} can now see what #{group.name} sees#{", until #{until_time.to_date}" if until_time}."
    end
  end

  def panel_refuse_request
    asked = panel_request
    asked.reject!(by: CurrentUser.user, note: params[:note].to_s)
    "Refused #{asked.user.name}'s request to join #{asked.creator_group.name}."
  end

  # --- the panel's lookups: every id through this gallery ---

  def panel_group
    @gallery.creator_groups.find_by(id: params[:group_id]) or
      raise Refused, "That group is not one of yours (or no longer exists). Reload the page and try again."
  end

  # The ticked groups, each one this gallery's own.
  def panel_group_ids
    ids = Array(params[:group_ids]).compact_blank.map(&:to_i).uniq
    if (ids - @gallery.creator_groups.where(id: ids).pluck(:id)).any?
      raise Refused, "That group is not one of yours (or no longer exists). Reload the page and try again."
    end

    ids
  end

  # A post this gallery controls now; missing and not-yours read alike.
  def panel_post(id)
    post = Post.find_by(id: id.to_s.strip.delete_prefix("#").presence)
    return post if post && CreatorControl.controller_gallery_ids([post]).fetch(post.id).include?(@gallery.id)

    raise Refused, format(NOT_YOUR_POST, id.to_s.strip.delete_prefix("#").to_i)
  end

  def panel_user(name)
    User.find_by_name(name.to_s.strip) or
      raise Refused, "No booru account is called \"#{name.to_s.strip}\". Check the spelling; the name field suggests names as you type."
  end

  def panel_request
    CreatorJoinRequest.where(creator_group_id: @gallery.creator_groups.select(:id)).find_by(id: params[:request_id]) or
      raise Refused, "That request is not waiting here (it may have been withdrawn or answered already)."
  end

  # "until" as the end of that day in the site's time zone, or nil.
  def panel_until
    date = params[:until].to_s.strip
    return nil if date.empty?
    raise Refused, "Write the date as YYYY-MM-DD, or leave it empty for no end." unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(date).in_time_zone.end_of_day
  rescue Date::Error
    raise Refused, "Write the date as YYYY-MM-DD, or leave it empty for no end."
  end

  def load_gallery
    @gallery = CreatorGallery.find_by!(slug: params.expect(:slug))
  end

  # The write gate: the request's VERIFIED Matrix identity must match this page's
  # owner, or the current Danbooru user must be an admin.
  def require_owner!
    return if owner_identity?
    return if CurrentUser.user.is_admin?

    raise User::PrivilegeError, "This page can only be edited by its owner, the Matrix account #{@gallery.matrix_id}, or by an admin. " \
                                "If it is yours, open #{creator_gallery_url(@gallery)}, use \"Sign in with Matrix\" there as #{@gallery.matrix_id}, then open Edit page again."
  end

  # The request's verified identity is this page's, on a request the booru's
  # own session authenticates (see the header: never an API-key request).
  def owner_identity?
    !api_request? && FourierIdentity.matches?(request, @gallery.matrix_id)
  end

  def api_request? = SessionLoader.new(request).has_api_authentication?

  # The verified owner, signed in to the booru as well and not banned: both
  # sessions at once, which is what linking an account or claiming a tag
  # needs. No admin override -- an admin is not the creator.
  def owner_signed_in?
    owner_identity? && !CurrentUser.user.is_anonymous? && !CurrentUser.user.is_banned?
  end

  def require_owner_signed_in!
    return if owner_signed_in?

    raise User::PrivilegeError, "Sign in to the booru (an unbanned account), with this page's Matrix identity, to do that."
  end

  # matrix_id is never mass-assigned: create reads it on its own (the
  # verified header, or an admin's explicit value) and nothing changes it
  # after. It is dropped before permit because unpermitted parameters raise
  # here (config/application.rb), which turned the admin's own "Matrix ID"
  # field on the new-page form into a 403.
  def gallery_params
    params.fetch(:creator_gallery, {}).except(:matrix_id).permit(:title, :bio, :style, :matrix_contact)
  end

  def slug_from(mxid)
    mxid.to_s.sub(/\A@/, "").split(":").first
  end

  def respond_change
    respond_to do |format|
      format.html { redirect_to edit_creator_gallery_path(@gallery) }
      format.json { render json: { ok: true, posts: @gallery.creator_gallery_posts.count, messages: @gallery.creator_gallery_messages.count } }
    end
  end
end
