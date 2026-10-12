# frozen_string_literal: true

module Admin
  # The creator-claim queue: who says a creator tag is theirs, and an admin's
  # answer (design CREATOR_VISIBILITY Q6, ruled 2026-10-07: admins approve).
  #
  # Both answers go through the model's own verbs, ArtistClaim#approve! and
  # #reject!, which refuse anyone but an admin and write the admin-only mod
  # log entry -- so this console and any later automation are one write path.
  # Rejected rather than deleted: the claimant may ask again, and "who was
  # refused, by whom, why" stays answerable.
  #
  # ORIGINAL CHARACTERS share the queue (CharacterClaim, ruled 2026-10-11):
  # the claims not clean enough to approve themselves, in a second table, and
  # decided through the same two routes with kind=character (no new routes).
  # kind absent is the creator-claim path, unchanged; any other kind is a 400.
  class ArtistClaimsController < ApplicationController
    respond_to :html

    def index
      authorize ArtistClaim
      @pending = ArtistClaim.pending.includes(:artist, creator_gallery: :user).order(:created_at, :id)
      @decided = ArtistClaim.where.not(status: ArtistClaim::PENDING).includes(:approver, creator_gallery: :user)
                            .order(decided_at: :desc, id: :desc).limit(50)
      @character_pending = CharacterClaim.pending.includes(creator_gallery: :user).order(:created_at, :id).to_a
      @character_decided = CharacterClaim.where.not(status: CharacterClaim::PENDING).includes(:approver, creator_gallery: :user)
                                         .order(decided_at: :desc, id: :desc).limit(50).to_a
      # Why each waiting claim was not approved when filed -- the history the
      # name already carries (posts, a wiki page, an alias into it) -- so the
      # admin sees what to look at. Up to three queries per waiting claim.
      @character_waits = @character_pending.to_h { |claim| [claim.id, claim.history] }
      # The rule as it stands NOW, per pending claim: the list is live, so a
      # claim valid when filed may not be at approval (approve! re-checks too).
      @refusals = @pending.to_h { |claim| [claim.id, ArtistClaim.refusal(claim.tag_name, claim.creator_gallery.matrix_id)] }
      @character_refusals = character_refusals
    rescue CreatorPrefixes::ConfigError => e
      @refusals = @character_refusals = nil
      flash.now[:notice] = "The claim rule cannot be checked: #{e.message}"
    end

    def approve
      return decide_character(:approve) if character?

      @claim = authorize ArtistClaim.find(params.expect(:id))
      @claim.approve!(by: CurrentUser.user)
      redirect_to admin_artist_claims_path, notice: "Approved: #{@claim.tag_name} is claimed by #{@claim.creator_gallery.matrix_id}."
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_artist_claims_path, notice: "Not approved: #{@claim.errors.full_messages.join("; ")}"
    rescue ActiveRecord::RecordNotUnique
      # The validations name every clash the two unique indexes guard; this is
      # two approvals racing to the index, which is still an answer, not a 500.
      redirect_to admin_artist_claims_path,
                  notice: "Not approved: #{@claim.tag_name} or its artist entry gained an approved claim meanwhile. Reload the queue to see it."
    end

    def reject
      return decide_character(:reject) if character?

      @claim = authorize ArtistClaim.find(params.expect(:id))
      @claim.reject!(by: CurrentUser.user, note: params[:note].to_s.strip)
      redirect_to admin_artist_claims_path, notice: "Rejected: #{@claim.creator_gallery.matrix_id}'s claim on #{@claim.tag_name}."
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_artist_claims_path, notice: "Not rejected: #{@claim.errors.full_messages.join("; ")}"
    end

    private

    def character?
      case params[:kind].presence
      when nil then false
      when "character" then true
      else raise ActionController::BadRequest, "kind must be character or absent (#{params[:kind].to_s.truncate(40).inspect} was sent)"
      end
    end

    # The second table's rule column: per pending claim, the rule as it
    # stands now; per decided approval, why it no longer stands (aliased
    # away, or the tag gone), nil when it does. Queries: one standing check,
    # one tag lookup, and the rule (up to three) per row, bounded by the
    # pending claims and the 50 decided.
    def character_refusals
      approved = @character_decided.select(&:approved?)
      standing = CharacterClaim.where(id: approved.map(&:id)).standing.map(&:id)
      tags = Tag.where(name: approved.map(&:tag_name)).pluck(:name)
      (@character_pending + approved).to_h do |claim|
        why = CharacterClaim.refusal(claim.tag_name, claim.slug)
        why ||= "the tag #{claim.tag_name} no longer exists" if claim.approved? && tags.exclude?(claim.tag_name)
        why ||= "no longer stands" if claim.approved? && standing.exclude?(claim.id)
        [claim.id, why]
      end
    end

    def decide_character(verdict)
      claim = authorize CharacterClaim.find(params.expect(:id)), :"#{verdict}?"
      back = admin_artist_claims_path(anchor: "character-claims")
      if verdict == :approve
        claim.approve!(by: CurrentUser.user)
        redirect_to back, notice: "Approved: #{claim.tag_name} is @#{claim.slug}'s original character."
      else
        claim.reject!(by: CurrentUser.user, note: params[:note].to_s.strip)
        redirect_to back, notice: "Rejected: @#{claim.slug}'s claim on #{claim.tag_name}."
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, notice: "Not #{(verdict == :approve) ? "approved" : "rejected"}: #{e.record.errors.full_messages.join("; ")}"
    rescue ActiveRecord::RecordNotUnique
      redirect_to back, notice: "Not approved: #{claim.tag_name} gained an approved claim meanwhile. Reload the queue to see it."
    end
  end
end
