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
  before_action :require_owner!, only: %i[edit update add_post remove_post create_message destroy_message]

  def index
    skip_authorization
    @galleries = CreatorGallery.order(updated_at: :desc).limit(60)
  end

  def show
    skip_authorization
  end

  def new
    skip_authorization
    @gallery = CreatorGallery.new
  end

  def edit
    skip_authorization
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
    return link_account if params[:link_account].present?
    return unlink_account if params[:unlink_account].present?
    return file_claim(params[:claim_tag]) if params[:claim_tag].present?

    if @gallery.update(gallery_params)
      redirect_to creator_gallery_path(@gallery)
    else
      render :edit, status: 422
    end
  end

  # --- curated posts ---
  def add_post
    skip_authorization
    post = Post.find(params.expect(:post_id))
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

  def load_gallery
    @gallery = CreatorGallery.find_by!(slug: params.expect(:slug))
  end

  # The write gate: the request's VERIFIED Matrix identity must match this page's
  # owner, or the current Danbooru user must be an admin.
  def require_owner!
    return if owner_identity?
    return if CurrentUser.user.is_admin?

    raise User::PrivilegeError, "This page can only be edited by its Matrix owner."
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
