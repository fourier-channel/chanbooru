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

  # WHO SEES IT (operator, 2026-10-07): members, not signed-out visitors --
  # who get the 404 a hidden post gets (MembersOnly) -- and each viewer only the rows for
  # prefixes they can see. A hidden prefix's row says which server is
  # archived and that its posts exist, which is part of what it hides, so it
  # and the posting accounts' names are for admins (and editors) alone. The
  # lookup matches only the rows shown: a hidden prefix answers as an
  # unlisted one does.
  def index
    skip_authorization
    user = CurrentUser.user
    MembersOnly.require!(user)

    @prefixes = CreatorPrefixes.entries.select { |e| CreatorPrefixes.sees?(e, user) }
    @editors = CreatorPrefixes.editor?(user) ? CreatorPrefixes.config[:editors] : nil
    @tag = params[:tag].to_s.strip.downcase.presence
    @match = @tag && @prefixes.find { |e| @tag.start_with?(e.prefix) || @tag == e.prefix.delete_suffix("_") }

    respond_to do |format|
      format.html
      format.json do
        body = { prefixes: @prefixes.map(&:to_h) }
        body[:editors] = @editors if @editors
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
    # Spoken to whoever released it: the creator releasing their own tag
    # hears "your", an admin hears whose (2026-10-09).
    whose = CreatorTagRelease.owner?(CurrentUser.user, tag) ? "your posts now follow your" : "the creator's posts now follow the creator's"
    flash[:notice] = released ? "#{tag} released: #{whose} own settings." : "#{tag} returned to its prefix's default."
    # From a creator's panel, land back on the setting the release hands
    # over to (the default audience), not at the top of a long edit page
    # (browser recheck, 2026-10-09). Same host only; anything else goes back
    # as before.
    back = begin
      URI.parse(request.referer.to_s)
    rescue URI::InvalidURIError
      nil
    end
    if back&.host == request.host && back.path.to_s.match?(%r{\A/creators/[^/]+/edit\z})
      redirect_to "#{back.path}#creator-panel-default"
    else
      redirect_back fallback_location: (CurrentUser.user.is_admin? ? releases_creator_prefixes_path : creator_prefixes_path)
    end
  rescue ActiveRecord::RecordInvalid => e
    flash[:notice] = e.record.errors.full_messages.join("; ")
    redirect_back fallback_location: creator_prefixes_path
  end
end
