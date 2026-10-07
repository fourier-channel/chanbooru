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

  # HIDDEN CREATORS, and releasing them (operator, 2026-10-07). Admin only:
  # the list names every creator under a hidden prefix, which is itself what
  # is hidden from everyone below admin.
  def releases
    raise User::PrivilegeError unless CurrentUser.user.is_admin?

    skip_authorization
    @hidden_prefixes = CreatorPrefixes.visibility_config[:entries].reject { |e| e.visible_to == "everyone" }
    @rows = @hidden_prefixes.flat_map do |entry|
      Tag.where("name LIKE ?", "#{Tag.sanitize_sql_like(entry.prefix)}%").order(post_count: :desc).pluck(:name, :post_count).map { |name, count| [entry, name, count] }
    end
    @releases = CreatorTagRelease.where(tag_name: @rows.map { |r| r[1] }).includes(:updater).index_by(&:tag_name)
    respond_to do |format|
      format.html
      format.json do
        render json: @rows.map { |entry, name, count|
          r = @releases[name]
          { tag: name, prefix: entry.prefix, visible_to: entry.visible_to, posts: count, released: r&.released || false,
            updated_by: r&.updater&.name, updated_at: r&.updated_at, note: r&.note }
        }
      end
    end
  end

  # Release a creator, or return them to their prefix's default. An admin, or
  # the creator through an approved claim on that exact tag (the artist page's
  # box posts here too).
  def update_release
    skip_authorization
    tag = params.require(:tag_name).to_s
    released = params[:released].to_s.truthy?
    CreatorTagRelease.set!(tag, released: released, by: CurrentUser.user, note: params[:note].to_s)
    flash[:notice] = released ? "#{tag} released: their posts now follow their own settings" : "#{tag} returned to its prefix's default"
    redirect_back fallback_location: (CurrentUser.user.is_admin? ? releases_creator_prefixes_path : creator_prefixes_path)
  rescue ActiveRecord::RecordInvalid => e
    flash[:notice] = e.record.errors.full_messages.join("; ")
    redirect_back fallback_location: creator_prefixes_path
  end
end
