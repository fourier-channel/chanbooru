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
  # Draws a NavSurface and decides nothing: which entries a viewer is
  # offered, their counts, the panel settings and the session observation are
  # all the surface's (interfaces stage 1, step 4a). The session bar (Manage
  # Session) is part of this header: a stationary, always-in-the-same-place
  # surface whose open state persists server-side.
  def initialize(surface:)
    super(current_user: surface.viewer)
    @surface = surface
  end

  attr_reader :surface

  delegate :entries, :observation, :session_bar_open?, to: :surface

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
end
