# frozen_string_literal: true

# THE SHADOW GUARD, run beside zeitwerk:check by both gate tiers
# (script/run-tests.sh: `bin/rails zeitwerk:check zeitwerk:shadowed`).
#
# zeitwerk:check does not see a file that defines a constant another autoload
# root already defines: Zeitwerk loads the first, records the second as
# "shadowed", logs it, and stays green. Stage 1 of the Modulation interfaces
# moves components from app/components into app/interfaces/<name>/components,
# collapsed to the same top-level names; a stale copy written back to the old
# path by another session would load in place of the moved one, silently.
# This makes that a failure.
namespace :zeitwerk do
  desc "Fail when an autoloaded file is shadowed by another file defining the same constant"
  task shadowed: :environment do
    loader = Rails.autoloaders.main
    loader.eager_load
    # Upstream requires a few app/logical files by hand before the loader
    # runs (config/application.rb, config/initializers/*): their constants are
    # already defined when Zeitwerk scans, so it records them as shadowed too.
    # Those files DID load, by require. A shadowed file that never loaded is
    # the one that is skipped, and only that one fails here.
    loaded = $LOADED_FEATURES.to_set
    shadowed = loader.__shadowed_files.reject { |file| loaded.include?(file) }
                     .map { |file| Pathname(file).relative_path_from(Rails.root).to_s }.sort

    if shadowed.empty?
      puts "zeitwerk:shadowed: no autoloaded file is shadowed (#{loader.__shadowed_files.size} were required by hand before the loader, and loaded)."
    else
      abort <<~MSG
        zeitwerk:shadowed: FAIL -- #{shadowed.size} file(s) define a constant another autoload root already defines, so they never load:
        #{shadowed.map { |file| "  #{file}" }.join("\n")}
        fix: keep one copy of each. A moved file left (or written back) at its old path is the usual cause; delete whichever is stale.
      MSG
    end
  end
end
