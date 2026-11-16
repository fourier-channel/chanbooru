# frozen_string_literal: true

# "Modulation" -- the redesigned single-cell post page (fourier fork). An opt-in
# experience preset rendered when ?preset=modulation is present; the upstream
# post page stays the default. Everything visual is token-driven (CSS custom
# properties) so a preset is just a bundle of overrides.
#
# It draws what its PostSurface returned and decides nothing (interfaces
# stage 1, step 4c): what this viewer may see of the post, its neighbours
# and its controls is the surface's, and the JSON door hands the client the
# same payload (ModulationController#show).
class ModulationPostComponent < ApplicationComponent
  attr_reader :surface

  delegate :post, :viewer, :comments_enabled?, :blacklist_data, to: :surface

  def initialize(surface:)
    super
    @surface = surface
  end

  # Built once a render: the page embeds it whole and sizes the stage from
  # its media.
  def payload
    @payload ||= surface.payload
  end
end
