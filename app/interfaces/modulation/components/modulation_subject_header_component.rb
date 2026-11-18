# frozen_string_literal: true

# The heading of a page about one subject -- an artist, a wiki page, a tag:
# the subject as a tag pill in its category's paint (the pill mixin), its post
# count, and its state as label chips (BANNED, deleted, locked, deprecated).
# The caller passes what to show; the category key comes from
# PostCards.category_key, never re-derived in a view.
class ModulationSubjectHeaderComponent < ApplicationComponent
  attr_reader :name, :href, :category_key, :count, :badges, :id, :prefix

  # @param name [String] the subject as shown (pretty_name, pretty_title)
  # @param href [String, nil] where the pill links; none draws a plain pill
  # @param category_key [String, nil] PostCards.category_key of its tag
  # @param count [Integer, nil] its post count; nil draws none
  # @param badges [Array<String>] state chips, in order
  # @param id [String, nil] the h1's id, for an id upstream's JS or tests key off
  #   (wiki_pages/show: wiki-page-title)
  # @param prefix [String, nil] a label before the pill ("Tag:")
  def initialize(name:, href: nil, category_key: nil, count: nil, badges: [], id: nil, prefix: nil) # rubocop:disable Metrics/ParameterLists
    super
    @name = name
    @href = href
    @category_key = category_key
    @count = count
    @badges = Array(badges).compact_blank
    @id = id
    @prefix = prefix
  end

  def pill_classes
    ["mod-pill", "mod-pill--subject", ("mod-pill--cat mod-pill--cat-#{category_key}" if category_key.present?)].compact.join(" ")
  end
end
