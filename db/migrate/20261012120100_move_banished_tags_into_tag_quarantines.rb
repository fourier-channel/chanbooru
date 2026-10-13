# frozen_string_literal: true

# THE BANISHED LIST MOVES INTO THE DATABASE (operator ruling 2026-10-12:
# Banish is one click from the review queue, so the list it adds to is a
# table, not a file). Danbooru.config.banished_tags -- a method in the
# UNTRACKED config/danbooru_local_config.rb -- is read once here, each name
# becomes a banished TagQuarantine row, and the method is then deleted from
# every copy (WORKING-RULES 7: one list, not two). Nothing reads it after.
#
# ORDER AT DEPLOY: run this while the method still exists, THEN delete it. A
# box whose config has already lost it raises here rather than silently
# migrating an empty list; under test there is no list to move.
class MoveBanishedTagsIntoTagQuarantines < ActiveRecord::Migration[8.1]
  NOTE = "moved from danbooru_local_config.rb banished_tags"

  def up
    names = banished_names
    now = Time.zone.now
    system = User.system
    moved = names.map(&:to_s).map(&:strip).compact_blank.uniq.count do |name|
      tag = Tag.find_or_create_by_name(name)
      next false if execute_count("SELECT 1 FROM tag_quarantines WHERE tag_id = #{tag.id.to_i}").positive?

      execute(<<~SQL.squish)
        INSERT INTO tag_quarantines (tag_id, state, banished_by_id, banished_at, note, created_at, updated_at)
        VALUES (#{tag.id.to_i}, 'banished', #{system.id.to_i}, #{quote(now)}, #{quote(NOTE)}, #{quote(now)}, #{quote(now)})
      SQL
      true
    end
    say "moved #{moved} of #{names.size} banished tags into tag_quarantines"
  end

  def down
    execute("DELETE FROM tag_quarantines WHERE note = #{quote(NOTE)}")
  end

  private

  def banished_names
    return [] if Rails.env.test?
    # Danbooru.config is an EnvironmentConfiguration (a method_missing
    # wrapper), so ask the configuration it wraps.
    unless Danbooru.config.config.respond_to?(:banished_tags)
      raise "run this migration BEFORE deleting banished_tags from config/danbooru_local_config.rb; " \
            "the tracked copy is fourier-basis ops/hetzner/danbooru/danbooru_local_config.rb"
    end

    Array(Danbooru.config.banished_tags)
  end

  def execute_count(sql) = select_values(sql).size
  def quote(value) = connection.quote(value)
end
