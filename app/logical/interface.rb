# frozen_string_literal: true

# THE INTERFACE REGISTRY: the interfaces that draw the booru, numbered.
#
# An interface is a folder, app/interfaces/<name>, plus one line in TABLE.
# Number 0 is classic: upstream's own drawing, in app/views where upstream
# keeps it, so upstream's changes keep landing there cleanly. Every other
# interface draws by overriding upstream's pages by path from <folder>/views,
# for its own viewers only, through its InterfaceResolver; a page it does not
# draw falls through to upstream's.
#
# ExperiencePreset picks a viewer's interface by name. The names are the
# preset names, so classic is still called "historical" there.
#
# - draws: every page the folder overrides, by virtual path ("posts/show",
#   "posts/index+window"). The folder and the list must agree.
# - capabilities: what a controller does differently for this interface,
#   by name (`windowed_gallery`), never by `if name == "modulation"`.
class Interface
  attr_reader :number, :name, :folder, :draws, :capabilities, :resolver

  def initialize(number:, name:, folder: nil, draws: [], capabilities: [])
    @number = number
    @name = name
    @folder = folder && Pathname(folder)
    @draws = draws.freeze
    @capabilities = capabilities.freeze
    # One resolver per interface, built with the registry; classic has none,
    # because app/views is already every controller's own view path.
    @resolver = InterfaceResolver.new(@folder.join("views")) unless classic?
    freeze
  end

  def classic?
    number == 0
  end

  def capable?(capability)
    capabilities.include?(capability)
  end

  TABLE = [
    new(number: 0, name: "historical"),
    new(number: 1, name: "modulation", folder: Rails.root.join("app/interfaces/modulation"),
        draws: %w[artists/show artists/show_or_new explore/posts/popular layouts/_color_scheme layouts/_navbar
                  posts/index posts/index+window posts/show sessions/new tags/show wiki_pages/show],
        capabilities: %w[windowed_gallery remembers_gallery_sort]),
  ].freeze

  # The `draws` key of a view file, by its path under a views folder:
  # posts/show.html.erb -> "posts/show", posts/index.html+window.erb ->
  # "posts/index+window", layouts/_slot.html.erb -> "layouts/_slot".
  def self.draws_key(relative)
    dir, base = File.split(relative)
    variant = base[/\+(\w+)\./, 1]
    "#{dir}/#{base.split(".").first}#{"+#{variant}" if variant}"
  end

  # @return [Interface] the interface named `name`
  def self.fetch(name)
    TABLE.find { |interface| interface.name == name } or
      raise KeyError, "no interface is named #{name.inspect}; fix: add its line to Interface::TABLE (app/logical/interface.rb), " \
                      "or ask for one of #{TABLE.map(&:name).join(", ")}"
  end
end
