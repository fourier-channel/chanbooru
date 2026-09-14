# frozen_string_literal: true

# Who may see fourier-sampling's curation surface, and in which view.
#
# The surface is published inside this site at `/sample` (operator ruling
# 2026-09-13) so it inherits the booru's authentication entirely rather than
# standing up its own gate, hostname and certificate. The reverse proxy hands
# that whole prefix to the sampling app -- Rails never renders the page, which
# is deliberate: the page streams server-sent events from `/api/events`, and
# proxying SSE through puma would hold a worker open for the life of every tab.
#
# What Rails is asked, and the only thing it is asked, is WHO IS THIS. Only
# Rails knows: the viewer's level lives in the booru session and nothing at the
# edge can read it. The proxy calls #authorize before serving any of `/sample`,
# serves nothing unless it answers 2xx, and copies one header out of the reply.
#
# TWO VIEWS, AND THE SPLIT IS NOT COSMETIC HERE. The sampling page has carried
# an internal/external toggle since before this, but it was a CSS rule --
# `body[data-view="external"]` hid five header blocks and the server served
# every route to everyone. Anyone could change the attribute, or skip the page
# and call the API, and reach the spend, the egress ledger, and every mutating
# route: jail an image, release one, apply jail policy, empty the junk bucket,
# steer acquisition. The sampling server now enforces an allowlist keyed on the
# header this controller sets, so the view decided here is the view served.
class SampleController < ApplicationController
  respond_to :json

  # OWNER ONLY, FOR NOW (operator ruling 2026-09-14). The surface is still
  # being shaped and is not ready to be looked at by anyone else, so the whole
  # prefix is refused below owner rather than downgraded to the external view.
  #
  # THE REFUSAL IS HERE AND NOT ONLY IN THE NAV. Hiding the link changes what
  # is offered, not what is reachable: /sample is a URL anyone can type, and
  # the proxy asks this endpoint and nothing else before it serves the prefix.
  # A restriction that lives in a template is not a restriction.
  #
  # The external view is kept rather than deleted. It is the half that decides
  # what a non-owner would be allowed to SEE if this is opened up again, and
  # its allowlist on the sampling side is the thing that actually keeps the
  # mutating routes out of reach. Deleting it here would leave that work
  # untested and make re-opening a rewrite rather than a one-line change.
  def authorize
    skip_authorization

    # Not signed in is a refusal, not an external view. The surface names
    # threads, boards and jail reasons; an invite-only site does not hand that
    # to an anonymous visitor just because it withholds the cost figures.
    #
    # Everyone below owner is refused the same way, for now, and for the same
    # reason: a 403 is the honest answer to "may I see this", and serving a
    # degraded page instead would imply the surface is ready for them.
    unless internal_viewer?
      render plain: "", status: :forbidden
      return
    end

    response.set_header("X-Fourier-View", "internal")
    head :no_content
  end

  private

  # Owner alone while the surface is being shaped. Admin was here until
  # 2026-09-14 and is deliberately not now; moderator never was, because a
  # moderator moderates the booru's content, which is a different question
  # from the machinery of acquisition.
  def internal_viewer?
    CurrentUser.user.is_owner?
  end
end
