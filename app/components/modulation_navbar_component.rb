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
    list << { label: "Creators", href: main_app.artists_path, category: "artist" }
    list << { label: "Tags", href: main_app.tags_path, category: "general" }
    list << { label: "Pools", href: main_app.gallery_pools_path, category: "general" }
    list << { label: "Wiki", href: main_app.wiki_page_path("help:home"), category: "general" }

    # The sampling curation surface, published inside this site at /sample
    # (operator ruling 2026-09-13) so it inherits the booru's authentication.
    #
    # Signed-in only, because the surface refuses anonymous outright -- showing
    # the pill to a visitor would be a link to a 403. Everyone signed in sees
    # the SAME pill; what differs is the view they are served when they follow
    # it, and that is decided server-side by SampleController#authorize, not
    # here. A nav that hid the entry from non-admins would be hiding a door
    # that is open, which is the weaker half of a boundary.
    # DISABLED until the page is integrated (operator, 2026-09-13). The surface
    # is reachable and gated, but its assets are still addressed from the site
    # root, so loading it under /sample would render unstyled markup with no
    # data. The pill goes in now, inert, and is lit when that is fixed --
    # shipping a live link to a broken page is the thing being avoided.
    list << { label: "Sample", category: "meta", disabled: true,
              disabled_reason: "Not yet linked -- the surface is still being integrated" } unless current_user.is_anonymous?

    if current_user.is_moderator?
      list << { label: "Reports", href: main_app.moderation_reports_path, category: "meta", count: pending_report_count }
      list << { label: "Dashboard", href: main_app.moderator_dashboard_path, category: "meta" }
    end

    list << { label: "More", href: main_app.site_map_path, category: "general" }
    list
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
end
