require "test_helper"

# Fork: script/anonymize_for_dev.sql refuses to run on a restored production
# copy unless every text-like column of every table is classified in its
# block -- a migration that adds one must classify it first. That refusal is
# met only at restore time, on the copy, after the migration has shipped.
# This meets it at test time, against structure.sql, with the guard's own
# block and type list read from the script.
class AnonymizeForDevClassificationTest < ActiveSupport::TestCase
  should "classify every text-like column of every table, and no column that is gone" do
    sql = Rails.root.join("script/anonymize_for_dev.sql").read
    block = sql[/regexp_split_to_table\(\$cls\$\n(.*?)\$cls\$/m, 1]
    types = sql[/c\.data_type IN \((.*?)\)\)/m, 1]
    assert(block && types, "the classification block or the guard's type list was not found in script/anonymize_for_dev.sql")

    classified = block.lines.map(&:strip).compact_blank.flat_map do |line|
      table, entries = line.split(":", 2)
      entries.split.map { |entry| "#{table.strip}.#{entry.split("=").first}" }
    end
    live = ApplicationRecord.connection.select_values(<<~SQL.squish)
      SELECT c.table_name || '.' || c.column_name FROM information_schema.columns c
        JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
       WHERE c.table_schema = 'public' AND c.data_type IN (#{types})
    SQL

    assert_equal([], (live - classified).sort, "unclassified in script/anonymize_for_dev.sql: classify each, handle it, and add it to the verify plan")
    assert_equal([], (classified - live).sort, "classified in script/anonymize_for_dev.sql but not in the schema")
  end
end
