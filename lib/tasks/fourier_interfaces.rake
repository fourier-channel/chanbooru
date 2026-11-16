# frozen_string_literal: true

# `bin/rails interfaces:table`: which interface draws which page.
#
# One row per page upstream draws (every template in app/views that is not a
# partial, by its `draws` key: "posts/show", "posts/index+window") and per
# partial an interface draws; one column per interface in Interface::TABLE.
# Classic (#0) is upstream's own drawing, so its column is always "upstream".
# Another interface's cell is "draws" where its `draws` lists the page and
# "falls through" where upstream's file answers for it.
#
# This prints what the registry says. Whether the folders agree with it is
# test/unit/interface_completeness_test.rb's job.
namespace :interfaces do
  desc "Print which interface draws which page"
  task table: :environment do
    views = Rails.root.join("app/views")
    pages = views.glob("**/*").select(&:file?).map { |file| file.relative_path_from(views).to_s }
                 .reject { |relative| File.basename(relative).start_with?("_") }
                 .map { |relative| Interface.draws_key(relative) }
    rows = (pages + Interface::TABLE.flat_map(&:draws)).uniq.sort
    columns = Interface::TABLE.map { |interface| "##{interface.number} #{interface.name}" }
    cell = lambda { |interface, key|
      if interface.classic?
        "upstream"
      else
        interface.draws.include?(key) ? "draws" : "falls through"
      end
    }

    width = [rows.map(&:size).max.to_i, 4].max
    widths = columns.map { |column| [column.size, "falls through".size].max }
    line = ->(cells) { cells.zip([width, *widths]).map { |text, size| text.ljust(size) }.join("  ").rstrip }
    puts line[["page", *columns]]
    rows.each { |key| puts line[[key, *Interface::TABLE.map { |interface| cell[interface, key] }]] }
    puts
    Interface::TABLE.reject(&:classic?).each do |interface|
      puts "##{interface.number} #{interface.name}: draws #{interface.draws.size} of #{rows.size} pages, #{rows.size - interface.draws.size} fall through"
    end
  end
end
