# frozen_string_literal: true

# The blocklist control: a small block icon with a count, joined to the
# purge/refresh rectangle in the header of every page, and the panel of
# pills it opens over the page (operator, 2026-10-13: "ubiquitous and located
# in the same place on every app, but not 'in the way'").
#
# It is also the page's ONLY filtering engine (Danbooru.Blacklist,
# blacklists.js): one per page, in the header, so every surface that marks
# posts -- the galleries, the post view, the landing carousel's pool -- is
# filtered by the same list. The root keeps upstream's #blacklist-box id and
# the engine its upstream class name; those are internal and nobody sees them.
#
# The person's own list is the only filter. Nothing site-enforced is sent:
# server withholding is the gate (see Blocklist).
class BlocklistComponent < ApplicationComponent
  attr_reader :user

  # @param user [User] the viewer. Signed out, the list starts empty here and
  #   the browser fills it from its own storage.
  def initialize(user:)
    super
    @user = user
  end

  def signed_in?
    !user.is_anonymous?
  end

  def blocks
    signed_in? ? user.blocklist : []
  end
end
