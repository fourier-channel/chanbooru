# frozen_string_literal: true

# One labelled panel on a drawn page ("Other names", "URLs", "Relationships",
# "Options"): the one Modulation panel (modulation-panel, the gallery's facet
# panel values) with the small mono label over its content.
class ModulationPanelComponent < ApplicationComponent
  attr_reader :label, :id, :classes

  # @param label [String, nil] the panel's label; none draws no heading
  # @param id [String, nil] the section's id
  # @param classes [String, nil] further classes on the section
  def initialize(label: nil, id: nil, classes: nil)
    super
    @label = label
    @id = id
    @classes = classes
  end

  def section_classes
    ["mod-panel", classes.presence].compact.join(" ")
  end
end
