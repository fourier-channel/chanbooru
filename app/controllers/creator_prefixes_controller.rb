# frozen_string_literal: true

# The creator-prefix list, read: what each prefix means, and the lookup.
#
# Operator, 2026-10-04: "It now provides a simple lookup mechanism for exact
# provenance and target simply by searching the prefix against the lock list."
# GET /creator_prefixes lists every entry; ?tag=aichan_selph (or a bare prefix)
# names the entry that tag carries. The list itself is edited on disk, never
# here (see CreatorPrefixes for where it lives and why).
#
# NOT under /fourier/ -- that prefix is reserved at nginx for the media gate.
class CreatorPrefixesController < ApplicationController
  respond_to :html, :json

  def index
    skip_authorization
    @prefixes = CreatorPrefixes.entries
    @editors = CreatorPrefixes.config[:editors]
    @tag = params[:tag].to_s.strip.downcase.presence
    @match = @tag && @prefixes.find { |e| @tag.start_with?(e.prefix) || @tag == e.prefix.delete_suffix("_") }

    respond_to do |format|
      format.html
      format.json do
        body = { editors: @editors, prefixes: @prefixes.map(&:to_h) }
        body.merge!(tag: @tag, match: @match&.to_h) if @tag
        render json: body
      end
    end
  rescue CreatorPrefixes::ConfigError => e
    respond_to do |format|
      format.html { render plain: e.message, status: :service_unavailable }
      format.json { render json: { error: e.message }, status: :service_unavailable }
    end
  end
end
