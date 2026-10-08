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
  class ArtistClaimsController < ApplicationController
    respond_to :html

    def index
      authorize ArtistClaim
      @pending = ArtistClaim.pending.includes(:artist, creator_gallery: :user).order(:created_at, :id)
      @decided = ArtistClaim.where.not(status: ArtistClaim::PENDING).includes(:approver, creator_gallery: :user)
                            .order(decided_at: :desc, id: :desc).limit(50)
      # The rule as it stands NOW, per pending claim: the list is live, so a
      # claim valid when filed may not be at approval (approve! re-checks too).
      @refusals = @pending.to_h { |claim| [claim.id, ArtistClaim.refusal(claim.tag_name, claim.creator_gallery.matrix_id)] }
    rescue CreatorPrefixes::ConfigError => e
      @refusals = nil
      flash.now[:notice] = "The claim rule cannot be checked: #{e.message}"
    end

    def approve
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
      @claim = authorize ArtistClaim.find(params.expect(:id))
      @claim.reject!(by: CurrentUser.user, note: params[:note].to_s.strip)
      redirect_to admin_artist_claims_path, notice: "Rejected: #{@claim.creator_gallery.matrix_id}'s claim on #{@claim.tag_name}."
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_artist_claims_path, notice: "Not rejected: #{@claim.errors.full_messages.join("; ")}"
    end
  end
end
