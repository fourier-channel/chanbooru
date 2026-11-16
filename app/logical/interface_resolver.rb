# frozen_string_literal: true

# An interface's views, in front of upstream's for one request, falling
# through ONE PAGE AT A TIME -- including per variant.
#
# A plain folder in front cannot do this. Rails takes the first view path
# with any match, and a page with no variant matches every variant request:
# with app/interfaces/modulation/views simply first, its posts/show.html.erb
# would answer the hover tooltip (/posts/:id?variant=tooltip) and draw the
# whole page there, in place of upstream's show.html+tooltip.erb. So the
# interface's plain page answers a variant request only when upstream has no
# file for that variant. An interface takes a variant over by adding the
# +variant file itself.
#
# It keeps no cache of its own, so it is safe across requests and threads.
# The folder's resolver is Rails' own, registered with ActionView::PathRegistry,
# so development's view reloading watches and clears it like app/views.
class InterfaceResolver < ActionView::Resolver
  def initialize(views)
    super()
    @views = ActionView::PathRegistry.cast_file_system_resolvers(views.to_s).first
  end

  delegate :to_s, :all_template_paths, :built_templates, to: :@views
  alias_method :to_path, :to_s

  private

  def _find_all(name, prefix, partial, details, key, locals)
    found = @views.find_all(name, prefix, partial, details, key, locals)
    variants = key ? key.variants : details[:variants]
    return found if found.empty? || found.first.variant.present? || !variants.is_a?(Array) || variants.empty?

    upstream_draws_variant = ActionController::Base.view_paths.any? do |resolver|
      resolver.find_all(name, prefix, partial, details, key, locals).any? { |template| template.variant.present? }
    end
    upstream_draws_variant ? [] : found
  end
end
