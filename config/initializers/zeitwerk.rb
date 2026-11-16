Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect({})
end

Rails.autoloaders.logger = Rails.logger

# Interfaces (app/logical/interface.rb): app/interfaces/<name> holds drawing
# only. Both its own folder and its components/ are collapsed, so a component
# keeps its top-level name -- collapsing components/ alone would make it
# Modulation::ModulationPostComponent and break every caller -- and views/
# holds templates, never constants.
Rails.autoloaders.main.collapse(Rails.root.join("app/interfaces/*"))
Rails.autoloaders.main.collapse(Rails.root.join("app/interfaces/*/components"))
Rails.autoloaders.main.ignore(Rails.root.join("app/interfaces/*/views"))
