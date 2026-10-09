# frozen_string_literal: true

class WebhooksController < ApplicationController
  skip_forgery_protection only: [:receive]

  rescue_with DiscordSlashCommand::WebhookVerificationError, status: 401
  # The refusal names what to fix (errors carry their own remedy, 2026-09-14).
  rescue_from(CreatorMembershipWebhook::VerificationError) { |error| render json: { error: error.message }, status: 401 }

  def receive
    skip_authorization

    case params[:source]
    when "discord"
      json = DiscordSlashCommand.receive_webhook(request)
      render json: json
    # The unused signed path for a sign-up provider (CREATOR_VISIBILITY Q5;
    # CreatorMembershipWebhook). Not an anonymous door: closed to callers
    # without a booru session until a provider exists (2026-10-09).
    when "creator_membership"
      status, json = CreatorMembershipWebhook.receive(request)
      render json: json, status: status
    else
      head 400
    end
  end
end
