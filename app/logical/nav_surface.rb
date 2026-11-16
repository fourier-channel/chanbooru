# frozen_string_literal: true

# What the site header offers THIS viewer: its entries and their counts, the
# viewer's panel settings and the session observation payload. Decided here,
# in core, so every interface's header draws the same decisions; a header
# that rebuilt them could miss a check and offer a door, or a count, the
# viewer was never meant to see.
#
# Takes the viewer, the request and the session as arguments and reads no
# CurrentUser: the header is drawn for whoever the caller names.
class NavSurface
  attr_reader :viewer, :request, :settings, :observation

  # `settings` is the viewer's ModulationSetting hash; `observation` is
  # SessionObservation.for_request -- the monitors' first read, served with
  # the page so the session bar renders true without a fetch.
  def initialize(viewer:, request:, session:)
    @viewer = viewer
    @request = request
    @settings = ModulationSetting.for_viewer(viewer, session)
    @observation = SessionObservation.for_request(request, viewer)
  end

  # The session bar's open state persists server-side.
  def session_bar_open?
    !!settings["session_bar_open"]
  end

  # Nav entries, in order, each with the TAG CATEGORY whose colour it borrows.
  #
  # Categories are named, never coloured, here: the palette differs between this
  # fork and upstream Danbooru, so "artist" has to mean "whatever artist tags
  # look like on this site" rather than a hex value. The SCSS resolves them
  # through --artist-tag-color and friends for the same reason.
  #
  # "Creators" is the artist tag index under a name that fits this site. Only it
  # is category-coloured; a header where every item shouts has no emphasis left
  # to spend.
  # No Login / My Account entry here any more: the ONE login/logout point is
  # the Manage Session control (operator ruling 2026-09-04), rendered beside
  # these entries in the template; account links live inside its bar.
  def entries
    list = []

    # No Comments, Notes or Forum. Those sections are retired (operator ruling
    # 2026-09-06) and 404 for everyone but the owner -- see
    # FourierRetiredSections. Dropping them from this list is the cosmetic half;
    # the concern is the half that closes the door.
    list << { label: "Posts", href: routes.posts_path, category: "general" }
    # Offered only where the door is open: a signed-out viewer is refused
    # everything off MembersOnly::ANONYMOUS_DOORS, and a pill that answers
    # "not found" is a pill that should not be there.
    list << { label: "Creators", href: routes.artists_path, category: "artist" } if offers?("artists#index")
    list << { label: "Tags", href: routes.tags_path, category: "general" } if offers?("tags#index")
    # The pool gallery is a listing of posts, members only (MembersOnly): a
    # signed-out visitor is not offered a pill that answers "not found".
    list << { label: "Pools", href: routes.gallery_pools_path, category: "general" } if MembersOnly.sees_post_listings?(viewer)
    # The wiki INDEX, not help:home. That page does not exist in this database
    # and the pill 404d in production -- a top-level nav item leading nowhere.
    # The help corpus was never written; the wiki itself works.
    list << { label: "Wiki", href: routes.wiki_pages_path, category: "general" } if offers?("wiki_pages#index")

    # The sampling curation surface, on its own host since 2026-10-09 (operator
    # ruling: it moves from /sample here to sample.41chan.net; the old paths
    # are retired, not redirected). Danbooru.config.fourier_sample_url is the
    # one place the address is written.
    #
    # SAME FRAME, NO TARGET (ruling 2026-10-09: "be absolutely sure that
    # calling sample from within the booru from within sample doesn't cause a
    # cascade"). Inside Technetium this page is a frame; the pill repaints that
    # frame, and sample's way back to the booru repaints it again, so going
    # back and forth never nests one frame in another. No `target`, no
    # `rel` that implies a new browsing context.
    #
    # OWNER ONLY, as it was (ruling 2026-09-14). The booru no longer decides
    # who may use the surface -- sample.41chan.net admits by Matrix power
    # level in the moderators' room (ruling 2026-10-09), which the booru
    # cannot read -- so this offers the door only to the one account certain
    # to be admitted. Hiding a link changes what is offered, not what is
    # reachable; the gate is sample's.
    list << { label: "Sample", href: Danbooru.config.fourier_sample_url, category: "meta" } if viewer.is_owner?

    if viewer.is_moderator?
      list << { label: "Reports", href: routes.moderation_reports_path, category: "meta", count: pending_report_count }
      list << { label: "Dashboard", href: routes.moderator_dashboard_path, category: "meta" }
    end

    # Creator claims waiting for an admin (CREATOR_VISIBILITY Q6, 2026-10-07:
    # admins decide). Shown only while something waits: the queue is rare
    # work, and the site map's Admin block is the standing way in.
    list << { label: "Claims", href: routes.admin_artist_claims_path, category: "meta", count: pending_claim_count } if viewer.is_admin? && pending_claim_count > 0

    # Flagged tags waiting for an admin's Release or Banish (TagQuarantine,
    # operator rulings 2026-10-12). Shown while something waits, like Claims.
    list << { label: "Flagged", href: routes.tags_path(search: { quarantine: "flagged" }), category: "meta", count: flagged_tag_count } if viewer.is_admin? && flagged_tag_count > 0

    # Join requests waiting for this creator (CREATOR_VISIBILITY Q5; the
    # creator panel, 2026-10-09): the creator is never sent a dmail per
    # request, so this is how they hear. Shown only while something waits,
    # like Claims; never asked for a signed-out viewer.
    if !viewer.is_anonymous? && pending_join_requests.any?
      list << { label: "Requests", href: routes.edit_creator_gallery_path(pending_join_requests.keys.first, view: "identity", anchor: "creator-panel-requests"),
                category: "meta", count: pending_join_requests.values.sum }
    end

    list << { label: "More", href: routes.site_map_path, category: "general" } if offers?("static#site_map")
    list
  end

  private

  def offers?(door)
    MembersOnly.offers?(viewer, request, door)
  end

  def routes
    Rails.application.routes.url_helpers
  end

  # Counted once, and only for the moderators who can see the entry at all.
  def pending_report_count
    @pending_report_count ||= ModerationReport.pending.count
  end

  # gallery slug => requests waiting, for the galleries linked to this
  # account, oldest waiting first: one query, once.
  def pending_join_requests
    @pending_join_requests ||= CreatorJoinRequest.pending.joins(creator_group: :creator_gallery)
                                                 .where(creator_galleries: { user_id: viewer.id })
                                                 .group("creator_galleries.slug").order(Arel.sql("min(creator_join_requests.created_at)")).count
  end

  # The flagged tags awaiting review, from the per-request quarantine set:
  # no query of its own.
  def flagged_tag_count
    @flagged_tag_count ||= TagQuarantine.flagged_names.size
  end

  # Counted once, and only for the admins who can see the entry at all: the
  # creator claims and the original character claims the queue holds.
  def pending_claim_count
    @pending_claim_count ||= ArtistClaim.pending.count + CharacterClaim.pending.count
  end
end
