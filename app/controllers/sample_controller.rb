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

  # Levels that get the internal view. Admin and owner, per the ruling, and
  # nothing inherited from moderator -- a moderator moderates the booru's
  # content, which is a different question from the machinery of acquisition.
  def authorize
    skip_authorization

    # Not signed in is a refusal, not an external view. The surface names
    # threads, boards and jail reasons; an invite-only site does not hand that
    # to an anonymous visitor just because it withholds the cost figures.
    if CurrentUser.user.is_anonymous?
      render plain: "", status: :forbidden
      return
    end

    response.set_header("X-Fourier-View", internal_viewer? ? "internal" : "external")
    head :no_content
  end

  private

  def internal_viewer?
    CurrentUser.user.is_admin? || CurrentUser.user.is_owner?
  end
end
