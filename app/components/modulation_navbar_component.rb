# frozen_string_literal: true

# The Modulation site header: a centred wordmark over a centred row of nav
# pills that use the same colour language as tags.
#
# A component of its own rather than a restyle of NavbarComponent, for the same
# reason the post view and gallery are their own components: upstream's header
# is what the `historical` preset must keep serving, and the two want different
# markup, not different CSS. NavbarComponent stays untouched.
#
# Inherits nav_link_match from it, though -- deciding which nav entry is
# "current" is a map of controller names to URL prefixes with nothing
# Modulation-specific about it, and copying it here would mean maintaining two.
class ModulationNavbarComponent < NavbarComponent
  # The session bar (Manage Session) is part of this header: a stationary,
  # always-in-the-same-place surface whose open state persists server-side.
  # `settings` is the viewer's ModulationSetting hash; `observation` is
  # SessionObservation.for_request -- the monitors' first read, served with
  # the page so the bar renders true without a fetch.
  def initialize(current_user:, settings: nil, observation: nil)
    super(current_user: current_user)
    @settings = settings || ModulationSetting.defaults
    @observation = observation
  end

  attr_reader :settings, :observation

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
    list << { label: "Posts", href: main_app.posts_path, category: "general" }
    # Offered only where the door is open: a signed-out viewer is refused
    # everything off MembersOnly::ANONYMOUS_DOORS, and a pill that answers
    # "not found" is a pill that should not be there.
    list << { label: "Creators", href: main_app.artists_path, category: "artist" } if offers?("artists#index")
    list << { label: "Tags", href: main_app.tags_path, category: "general" } if offers?("tags#index")
    # The pool gallery is a listing of posts, members only (MembersOnly): a
    # signed-out visitor is not offered a pill that answers "not found".
    list << { label: "Pools", href: main_app.gallery_pools_path, category: "general" } if MembersOnly.sees_post_listings?(current_user)
    # The wiki INDEX, not help:home. That page does not exist in this database
    # and the pill 404d in production -- a top-level nav item leading nowhere.
    # The help corpus was never written; the wiki itself works.
    list << { label: "Wiki", href: main_app.wiki_pages_path, category: "general" } if offers?("wiki_pages#index")

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
    list << { label: "Sample", href: Danbooru.config.fourier_sample_url, category: "meta" } if current_user.is_owner?

    if current_user.is_moderator?
      list << { label: "Reports", href: main_app.moderation_reports_path, category: "meta", count: pending_report_count }
      list << { label: "Dashboard", href: main_app.moderator_dashboard_path, category: "meta" }
    end

    # Creator claims waiting for an admin (CREATOR_VISIBILITY Q6, 2026-10-07:
    # admins decide). Shown only while something waits: the queue is rare
    # work, and the site map's Admin block is the standing way in.
    list << { label: "Claims", href: main_app.admin_artist_claims_path, category: "meta", count: pending_claim_count } if current_user.is_admin? && pending_claim_count > 0

    list << { label: "More", href: main_app.site_map_path, category: "general" } if offers?("static#site_map")
    list
  end

  def offers?(door)
    MembersOnly.offers?(current_user, helpers.request, door)
  end

  def current?(entry)
    # The landing page is not a nav destination, and upstream's matcher falls
    # through to /static for controllers it does not know -- which made "More"
    # light up on the front page.
    return false if helpers.controller_name == "landing"

    nav_link_match(entry[:href]).present?
  end

  # Namespaced away from upstream's nav ids on purpose. NavbarComponent's
  # stylesheet targets #main-menu, #subnav-menu and #nav-login, and it is loaded
  # on every page -- reusing those ids here meant upstream's header styles
  # reached into this component and quietly recoloured the login pill.
  def dom_id(entry)
    entry[:id].presence || "modnav-#{entry[:label].parameterize}"
  end

  def app_name
    Danbooru.config.app_name
  end

  private

  # Counted once, and only for the moderators who can see the entry at all.
  def pending_report_count
    @pending_report_count ||= ModerationReport.pending.count
  end

  # Counted once, and only for the admins who can see the entry at all.
  def pending_claim_count
    @pending_claim_count ||= ArtistClaim.pending.count
  end
end
